-- Fase C da integracao Open Finance (ESPECIFICACAO.md 14.5/14.6/14.11):
-- motor de casamento e acoes de revisao. Toda a regra mora aqui, no banco.
--
-- As funcoes que escrevem sao `security definer` (rodam como o dono, sem RLS)
-- e por isso filtram user_id explicitamente em TODA leitura e escrita -- a
-- armadilha classica de security definer, coberta pelo teste 06.

-- Descricao normalizada para comparar textos do banco com os do usuario
-- ("PIX ENVIADO JOSÉ" ~ "pix enviado jose"): minusculas, sem acento, sem
-- digitos nem pontuacao.
create or replace function normalizar_descricao(t text)
returns text language sql stable
set search_path = public, extensions as $$
  select btrim(regexp_replace(lower(unaccent(coalesce(t, ''))), '[^a-z]+', ' ', 'g'));
$$;

-- Padrao de uma regra de categoria: as 3 primeiras palavras normalizadas.
create or replace function padrao_descricao(t text)
returns text language sql stable
set search_path = public, extensions as $$
  select array_to_string((regexp_split_to_array(normalizar_descricao(t), ' '))[1:3], ' ');
$$;

-- Usuario efetivo de uma chamada: o logado; ou, sem sessao (service_role nas
-- Edge Functions, Fase D), o informado. Logado nunca age por outro usuario.
create or replace function usuario_efetivo(uid uuid)
returns uuid language plpgsql stable as $$
begin
  if auth.uid() is not null then
    if uid is not null and uid <> auth.uid() then
      raise exception 'sem permissao para agir por outro usuario';
    end if;
    return auth.uid();
  end if;
  if uid is null then
    raise exception 'usuario obrigatorio';
  end if;
  return uid;
end;
$$;

-- Marca o vinculo na linha da staging (e, para avulso, o lado do avulso).
create or replace function _vincular(t_id uuid, uid uuid, tipo text, alvo uuid, automatico boolean, anterior jsonb)
returns void language plpgsql security definer
set search_path = public, extensions as $$
begin
  if tipo = 'avulso' then
    update avulsos set transacao_banco_id = t_id where id = alvo and user_id = uid;
  end if;
  update transacoes_bancarias
     set estado = 'vinculada', vinculo_tipo = tipo, vinculo_id = alvo,
         vinculo_automatico = automatico, vinculo_anterior = anterior,
         candidatos = '[]'::jsonb, atualizada_em = now()
   where id = t_id and user_id = uid;
end;
$$;

-- Marca uma execucao como paga pela transacao do banco, guardando o estado
-- anterior para o desfazer. Devolve o id da execucao.
create or replace function _pagar_execucao(t_id uuid, uid uuid, rec_id uuid, c date, valor numeric, d date, automatico boolean)
returns uuid language plpgsql security definer
set search_path = public, extensions as $$
declare
  anterior jsonb;
  exec_id uuid;
begin
  select to_jsonb(e) into anterior
  from execucoes e
  where e.user_id = uid and e.recorrente_id = rec_id and e.ciclo = c;

  insert into execucoes (user_id, ciclo, recorrente_id, valor_realizado, status, data_efetiva)
  values (uid, c, rec_id, valor, 'pago', d)
  on conflict (user_id, ciclo, recorrente_id)
  do update set status = 'pago', valor_realizado = excluded.valor_realizado,
                data_efetiva = excluded.data_efetiva
  returning id into exec_id;

  perform _vincular(t_id, uid, 'execucao', exec_id, automatico, anterior);
  return exec_id;
end;
$$;

-- O motor (14.6). Idempotente: percorre o que esta `para_revisar`, na ordem
-- das datas; a primeira regra que casar vence. Casa sozinho so quando ha UM
-- candidato inequivoco; o resto vira sugestao em `candidatos` (e, por ter
-- candidato, nao conta como provisorio -- ver v_banco_provisorio).
create or replace function casar_transacoes_bancarias(uid uuid default null)
returns int language plpgsql security definer
set search_path = public, extensions as $$
declare
  u uuid := usuario_efetivo(uid);
  t record;
  cand jsonb;
  n int;
  auto_ok boolean;
  ref_compra date;
  ciclo_t date;
  meio_t meio_pagamento;
  p_alvo record;
  r_alvo record;
  a_alvo record;
  casadas int := 0;
begin
  for t in
    select * from transacoes_bancarias
    where user_id = u and estado = 'para_revisar'
    order by data, id
  loop
    cand := '[]'::jsonb;
    auto_ok := not t.bloquear_auto;
    meio_t := coalesce(t.meio_inferido, case when t.tipo_conta = 'CREDIT' then 'credito' else 'debito' end::meio_pagamento);
    ciclo_t := ciclo_caixa(t.data, meio_t, u);
    ref_compra := coalesce(t.data_compra_original, t.data);

    -- 1. Liquidacao de fatura: nao e gasto, liquida compras ja contadas.
    if t.tipo_conta = 'CREDIT' and t.tipo_operacao = 'PAGAMENTO_FATURA' then
      if auto_ok then
        perform _vincular(t.id, u, 'liquidacao', null, true, null);
        casadas := casadas + 1;
        continue;
      end if;
      cand := cand || jsonb_build_array(jsonb_build_object('tipo', 'liquidacao'));
    elsif t.tipo_conta = 'BANK' and t.sentido = 'despesa' and exists (
      select 1 from transacoes_bancarias c
      where c.user_id = u and c.tipo_conta = 'CREDIT' and c.tipo_operacao = 'PAGAMENTO_FATURA'
        and c.valor = t.valor and abs(c.data - t.data) <= 3
    ) then
      if auto_ok then
        perform _vincular(t.id, u, 'liquidacao', null, true, null);
        casadas := casadas + 1;
        continue;
      end if;
      cand := cand || jsonb_build_array(jsonb_build_object('tipo', 'liquidacao'));
    end if;

    -- 2. Parcela de parcelamento cadastrado (so cartao).
    if t.tipo_conta = 'CREDIT' and t.sentido = 'despesa' and coalesce(t.parcela_total, 0) > 1 then
      select count(*) into n
      from parcelamentos p
      where p.user_id = u and p.meio_pagamento = 'credito'
        and p.valor_parcela = t.valor and p.num_parcelas = t.parcela_total
        and abs(p.data_compra - coalesce(t.data_compra_original,
              (t.data - (coalesce(t.parcela_numero, 1) - 1) * interval '1 month')::date)) <= 5
        and not exists (
          select 1 from transacoes_bancarias o
          where o.user_id = u and o.vinculo_tipo = 'parcelamento' and o.vinculo_id = p.id
            and o.parcela_numero is not distinct from t.parcela_numero and o.id <> t.id);
      if n > 0 then
        select p.* into p_alvo
        from parcelamentos p
        where p.user_id = u and p.meio_pagamento = 'credito'
          and p.valor_parcela = t.valor and p.num_parcelas = t.parcela_total
          and abs(p.data_compra - coalesce(t.data_compra_original,
                (t.data - (coalesce(t.parcela_numero, 1) - 1) * interval '1 month')::date)) <= 5
          and not exists (
            select 1 from transacoes_bancarias o
            where o.user_id = u and o.vinculo_tipo = 'parcelamento' and o.vinculo_id = p.id
              and o.parcela_numero is not distinct from t.parcela_numero and o.id <> t.id)
        order by p.data_compra
        limit 1;
        if n = 1 and auto_ok then
          perform _vincular(t.id, u, 'parcelamento', p_alvo.id, true, null);
          casadas := casadas + 1;
          continue;
        end if;
        cand := cand || (
          select coalesce(jsonb_agg(jsonb_build_object('tipo', 'parcelamento', 'id', p.id,
                   'descricao', p.descricao, 'valor', p.valor_parcela)), '[]'::jsonb)
          from parcelamentos p
          where p.user_id = u and p.meio_pagamento = 'credito'
            and p.valor_parcela = t.valor and p.num_parcelas = t.parcela_total);
      end if;
    end if;

    -- 3. Recorrente esperado no ciclo (salario, assinatura, conta, emprestimo).
    select count(*) into n
    from recorrentes r
    left join execucoes e on e.user_id = u and e.recorrente_id = r.id and e.ciclo = ciclo_t
    where r.user_id = u and r.ativo and r.tipo = t.sentido
      and (r.meio_pagamento = 'credito') = (t.tipo_conta = 'CREDIT')
      and ciclo_caixa(r.data_inicio, r.meio_pagamento, u) <= ciclo_t
      and (r.data_fim is null or ciclo_t <= ciclo_caixa(r.data_fim, r.meio_pagamento, u))
      and case when r.estimado
               then t.valor between r.valor_previsto * 0.7 and r.valor_previsto * 1.3
               else t.valor = coalesce(e.valor_realizado, r.valor_previsto) end
      and not exists (select 1 from transacoes_bancarias o
                      where o.user_id = u and o.vinculo_tipo = 'execucao' and o.vinculo_id = e.id);
    if n > 0 then
      select r.*, similarity(normalizar_descricao(r.descricao), normalizar_descricao(t.descricao)) as sim
        into r_alvo
      from recorrentes r
      left join execucoes e on e.user_id = u and e.recorrente_id = r.id and e.ciclo = ciclo_t
      where r.user_id = u and r.ativo and r.tipo = t.sentido
        and (r.meio_pagamento = 'credito') = (t.tipo_conta = 'CREDIT')
        and ciclo_caixa(r.data_inicio, r.meio_pagamento, u) <= ciclo_t
        and (r.data_fim is null or ciclo_t <= ciclo_caixa(r.data_fim, r.meio_pagamento, u))
        and case when r.estimado
                 then t.valor between r.valor_previsto * 0.7 and r.valor_previsto * 1.3
                 else t.valor = coalesce(e.valor_realizado, r.valor_previsto) end
        and not exists (select 1 from transacoes_bancarias o
                        where o.user_id = u and o.vinculo_tipo = 'execucao' and o.vinculo_id = e.id)
      order by sim desc
      limit 1;
      -- Sozinho so com valor fixo exato E alguma evidencia alem do valor:
      -- descricao parecida, ou (fora do cartao) a data perto do dia previsto.
      if n = 1 and auto_ok and not r_alvo.estimado and (
           r_alvo.sim >= 0.2
           or (t.tipo_conta = 'BANK' and abs(t.data - dia_no_ciclo(ciclo_t, r_alvo.dia_referencia)) <= 3)
         ) then
        perform _pagar_execucao(t.id, u, r_alvo.id, ciclo_t, t.valor, t.data, true);
        casadas := casadas + 1;
        continue;
      end if;
      cand := cand || (
        select coalesce(jsonb_agg(jsonb_build_object('tipo', 'recorrente', 'id', r.id, 'ciclo', ciclo_t,
                 'descricao', r.descricao, 'valor', r.valor_previsto)), '[]'::jsonb)
        from recorrentes r
        left join execucoes e on e.user_id = u and e.recorrente_id = r.id and e.ciclo = ciclo_t
        where r.user_id = u and r.ativo and r.tipo = t.sentido
          and (r.meio_pagamento = 'credito') = (t.tipo_conta = 'CREDIT')
          and ciclo_caixa(r.data_inicio, r.meio_pagamento, u) <= ciclo_t
          and (r.data_fim is null or ciclo_t <= ciclo_caixa(r.data_fim, r.meio_pagamento, u))
          and case when r.estimado
                   then t.valor between r.valor_previsto * 0.7 and r.valor_previsto * 1.3
                   else t.valor = coalesce(e.valor_realizado, r.valor_previsto) end
          and not exists (select 1 from transacoes_bancarias o
                          where o.user_id = u and o.vinculo_tipo = 'execucao' and o.vinculo_id = e.id));
    end if;

    -- 4. Lancamento manual existente: mesmo sentido, mesmo valor, data +-2 dias.
    select count(*) into n
    from avulsos a
    where a.user_id = u and a.transacao_banco_id is null and a.tipo = t.sentido
      and (a.meio_pagamento = 'credito') = (t.tipo_conta = 'CREDIT')
      and a.valor = t.valor and abs(a.data - ref_compra) <= 2;
    if n = 1 and auto_ok then
      select a.* into a_alvo
      from avulsos a
      where a.user_id = u and a.transacao_banco_id is null and a.tipo = t.sentido
        and (a.meio_pagamento = 'credito') = (t.tipo_conta = 'CREDIT')
        and a.valor = t.valor and abs(a.data - ref_compra) <= 2;
      perform _vincular(t.id, u, 'avulso', a_alvo.id, true, null);
      casadas := casadas + 1;
      continue;
    end if;
    -- Mais de um, ou valor um pouco diferente (ate 10%, +-3 dias): sugestao.
    cand := cand || (
      select coalesce(jsonb_agg(jsonb_build_object('tipo', 'avulso', 'id', a.id,
               'descricao', a.descricao, 'valor', a.valor, 'data', a.data)), '[]'::jsonb)
      from avulsos a
      where a.user_id = u and a.transacao_banco_id is null and a.tipo = t.sentido
        and (a.meio_pagamento = 'credito') = (t.tipo_conta = 'CREDIT')
        and abs(a.valor - t.valor) <= t.valor * 0.10 and abs(a.data - ref_compra) <= 3);

    -- 5. Sem casamento: fica para revisar, com categoria sugerida pelas regras
    -- aprendidas (so depois de 2 confirmacoes do mesmo padrao).
    update transacoes_bancarias
       set candidatos = cand,
           categoria_sugerida_id = (
             select rc.categoria_id from regras_categoria rc
             where rc.user_id = u and rc.ativa and rc.confirmacoes >= 2
               and normalizar_descricao(t.descricao) like rc.padrao || '%'
             order by length(rc.padrao) desc
             limit 1),
           atualizada_em = now()
     where id = t.id and user_id = u;
  end loop;

  return casadas;
end;
$$;

-- ===== Acoes de revisao (tela "Para revisar", 14.11). Sempre do usuario logado.

-- Confirmar: vira um avulso (a contagem muda de caminho: provisorio -> avulso,
-- sem somar duas vezes) e ensina a regra de categoria.
create or replace function confirmar_transacao(
  p_id uuid, p_categoria uuid, p_meio meio_pagamento default null, p_descricao text default null)
returns uuid language plpgsql security definer
set search_path = public, extensions as $$
declare
  u uuid := auth.uid();
  t transacoes_bancarias;
  novo uuid;
  meio meio_pagamento;
  pad text;
begin
  if u is null then raise exception 'sessao obrigatoria'; end if;
  select * into t from transacoes_bancarias
   where id = p_id and user_id = u and estado = 'para_revisar' for update;
  if not found then raise exception 'transacao nao encontrada ou ja revisada'; end if;
  if not exists (select 1 from categorias where id = p_categoria and user_id = u) then
    raise exception 'categoria invalida';
  end if;

  meio := coalesce(p_meio, t.meio_inferido,
                   case when t.tipo_conta = 'CREDIT' then 'credito' else 'debito' end::meio_pagamento);
  insert into avulsos (user_id, data, descricao, tipo, categoria_id, meio_pagamento, valor)
  values (u, coalesce(t.data_compra_original, t.data), coalesce(nullif(btrim(p_descricao), ''), t.descricao),
          t.sentido, p_categoria, meio, t.valor)
  returning id into novo;

  update avulsos set transacao_banco_id = t.id where id = novo;
  update transacoes_bancarias
     set estado = 'confirmada', vinculo_tipo = 'avulso', vinculo_id = novo,
         vinculo_automatico = false, candidatos = '[]'::jsonb, atualizada_em = now()
   where id = t.id;

  pad := padrao_descricao(t.descricao);
  if pad <> '' then
    insert into regras_categoria (user_id, padrao, categoria_id, meio_pagamento)
    values (u, pad, p_categoria, meio)
    on conflict (user_id, padrao) do update
      set confirmacoes = case when regras_categoria.categoria_id = excluded.categoria_id
                              then regras_categoria.confirmacoes + 1 else 1 end,
          categoria_id = excluded.categoria_id,
          meio_pagamento = excluded.meio_pagamento;
  end if;
  return novo;
end;
$$;

create or replace function ignorar_transacao(p_id uuid)
returns void language plpgsql security definer
set search_path = public, extensions as $$
begin
  if auth.uid() is null then raise exception 'sessao obrigatoria'; end if;
  update transacoes_bancarias
     set estado = 'ignorada', candidatos = '[]'::jsonb, atualizada_em = now()
   where id = p_id and user_id = auth.uid() and estado = 'para_revisar';
  if not found then raise exception 'transacao nao encontrada ou ja revisada'; end if;
end;
$$;

-- Vincular a algo que ja existe: 'avulso' | 'parcelamento' | 'recorrente'
-- (p_alvo = recorrente; p_ciclo opcional, padrao o ciclo da transacao) |
-- 'liquidacao' (pagamento de fatura; p_alvo nulo).
create or replace function vincular_transacao(p_id uuid, p_tipo text, p_alvo uuid default null, p_ciclo date default null)
returns void language plpgsql security definer
set search_path = public, extensions as $$
declare
  u uuid := auth.uid();
  t transacoes_bancarias;
begin
  if u is null then raise exception 'sessao obrigatoria'; end if;
  select * into t from transacoes_bancarias
   where id = p_id and user_id = u and estado = 'para_revisar' for update;
  if not found then raise exception 'transacao nao encontrada ou ja revisada'; end if;

  if p_tipo = 'avulso' then
    if not exists (select 1 from avulsos where id = p_alvo and user_id = u and transacao_banco_id is null) then
      raise exception 'lancamento invalido ou ja vinculado';
    end if;
    perform _vincular(t.id, u, 'avulso', p_alvo, false, null);
  elsif p_tipo = 'parcelamento' then
    if not exists (select 1 from parcelamentos where id = p_alvo and user_id = u) then
      raise exception 'parcelamento invalido';
    end if;
    perform _vincular(t.id, u, 'parcelamento', p_alvo, false, null);
  elsif p_tipo = 'recorrente' then
    if not exists (select 1 from recorrentes where id = p_alvo and user_id = u) then
      raise exception 'recorrente invalido';
    end if;
    perform _pagar_execucao(t.id, u, p_alvo,
      coalesce(p_ciclo, ciclo_caixa(t.data,
        coalesce(t.meio_inferido, case when t.tipo_conta = 'CREDIT' then 'credito' else 'debito' end::meio_pagamento), u)),
      t.valor, t.data, false);
  elsif p_tipo = 'liquidacao' then
    perform _vincular(t.id, u, 'liquidacao', null, false, null);
  else
    raise exception 'tipo de vinculo invalido: %', p_tipo;
  end if;
end;
$$;

-- Desfazer: volta para "Para revisar" e desfaz o que a confirmacao/vinculo
-- criou. Bloqueia o casamento automatico dessa transacao (senao o motor
-- refaria o mesmo vinculo na proxima rodada).
create or replace function desfazer_transacao(p_id uuid)
returns void language plpgsql security definer
set search_path = public, extensions as $$
declare
  u uuid := auth.uid();
  t transacoes_bancarias;
begin
  if u is null then raise exception 'sessao obrigatoria'; end if;
  select * into t from transacoes_bancarias
   where id = p_id and user_id = u and estado in ('confirmada', 'vinculada', 'ignorada') for update;
  if not found then raise exception 'transacao nao encontrada ou nao revisada'; end if;

  if t.estado = 'confirmada' then
    delete from avulsos where id = t.vinculo_id and user_id = u and transacao_banco_id = t.id;
  elsif t.vinculo_tipo = 'avulso' then
    update avulsos set transacao_banco_id = null where id = t.vinculo_id and user_id = u;
  elsif t.vinculo_tipo = 'execucao' then
    if t.vinculo_anterior is null then
      delete from execucoes where id = t.vinculo_id and user_id = u;
    else
      update execucoes
         set status = (t.vinculo_anterior ->> 'status')::status_execucao,
             valor_realizado = (t.vinculo_anterior ->> 'valor_realizado')::numeric,
             data_efetiva = (t.vinculo_anterior ->> 'data_efetiva')::date
       where id = t.vinculo_id and user_id = u;
    end if;
  end if;

  update transacoes_bancarias
     set estado = 'para_revisar', vinculo_tipo = null, vinculo_id = null,
         vinculo_automatico = false, vinculo_anterior = null,
         bloquear_auto = true, atualizada_em = now()
   where id = t.id;
end;
$$;

-- ===== Integridade com o resto do app

-- O cliente nunca define transacao_banco_id direto (so as funcoes acima, que
-- rodam como o dono). Sem isso, um UPDATE em avulsos poderia apontar para a
-- transacao de outra pessoa (a FK nao passa pelo RLS).
create or replace function proteger_transacao_banco_id()
returns trigger language plpgsql as $$
begin
  if current_user in ('anon', 'authenticated')
     and new.transacao_banco_id is distinct from
         (case when tg_op = 'UPDATE' then old.transacao_banco_id end) then
    raise exception 'transacao_banco_id so e definido pela revisao bancaria';
  end if;
  return new;
end;
$$;

create trigger avulsos_proteger_transacao_banco_id
before insert or update on avulsos
for each row execute function proteger_transacao_banco_id();

-- Apagar no app algo que estava vinculado devolve a transacao do banco para
-- "Para revisar" -- senao ela deixaria de contar em qualquer lugar.
create or replace function devolver_transacao_para_revisao()
returns trigger language plpgsql security definer
set search_path = public, extensions as $$
begin
  update transacoes_bancarias
     set estado = 'para_revisar', vinculo_tipo = null, vinculo_id = null,
         vinculo_automatico = false, vinculo_anterior = null,
         bloquear_auto = true, atualizada_em = now()
   where user_id = old.user_id and vinculo_id = old.id
     and vinculo_tipo = case tg_table_name
                          when 'avulsos' then 'avulso'
                          when 'parcelamentos' then 'parcelamento'
                          when 'execucoes' then 'execucao' end;
  return old;
end;
$$;

create trigger avulsos_devolver_transacao after delete on avulsos
for each row execute function devolver_transacao_para_revisao();
create trigger parcelamentos_devolver_transacao after delete on parcelamentos
for each row execute function devolver_transacao_para_revisao();
create trigger execucoes_devolver_transacao after delete on execucoes
for each row execute function devolver_transacao_para_revisao();

-- ===== Permissoes: so quem precisa executa. Funcoes nascem executaveis por
-- PUBLIC no Postgres; tirar isso e o que impede `anon` de chama-las.
revoke execute on function
  _vincular(uuid, uuid, text, uuid, boolean, jsonb),
  _pagar_execucao(uuid, uuid, uuid, date, numeric, date, boolean),
  casar_transacoes_bancarias(uuid),
  confirmar_transacao(uuid, uuid, meio_pagamento, text),
  ignorar_transacao(uuid),
  vincular_transacao(uuid, text, uuid, date),
  desfazer_transacao(uuid),
  devolver_transacao_para_revisao(),
  usuario_efetivo(uuid)
from public, anon;

grant execute on function
  casar_transacoes_bancarias(uuid),
  confirmar_transacao(uuid, uuid, meio_pagamento, text),
  ignorar_transacao(uuid),
  vincular_transacao(uuid, text, uuid, date),
  desfazer_transacao(uuid),
  normalizar_descricao(text),
  padrao_descricao(text)
to authenticated;

grant execute on function casar_transacoes_bancarias(uuid) to service_role;
