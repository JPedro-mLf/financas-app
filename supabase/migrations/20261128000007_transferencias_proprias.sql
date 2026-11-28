-- Transferencias do proprio CPF e juros do cheque especial (ESPECIFICACAO.md
-- 14.22, decisoes do usuario em 28/11/2026).
--
-- Dados reais do v2: das transferencias do proprio CPF, 50 saidas e 50
-- entradas formam pares exatos (mesma soma ao centavo) entre contas
-- conectadas; 23 entradas (R$ 12.683) nao tem par -- vem de conta NAO
-- conectada (Banco do Brasil, onde o usuario recebe depositos), e por isso
-- sao dinheiro novo no controle do app.
--
--   par saida+entrada entre contas conectadas -> 'interna': nao conta, sozinha
--   entrada do proprio CPF sem par            -> conta como entrada
--   saida para o proprio CPF sem par          -> fica para revisar (pode ser
--                                                guardar dinheiro ou pagar algo)
--   juros/encargos do cheque especial         -> contam como despesa na hora

alter table transacoes_bancarias drop constraint transacoes_bancarias_vinculo_tipo_check;
alter table transacoes_bancarias add constraint transacoes_bancarias_vinculo_tipo_check
  check (vinculo_tipo in ('execucao', 'parcelamento', 'avulso', 'liquidacao', 'interna'));

create or replace function eh_transferencia(t transacoes_bancarias)
returns boolean language sql immutable as $$
  select coalesce(t.tipo_conta = 'BANK'
    and t.tipo_operacao in ('PIX', 'TRANSFERENCIA_MESMA_INSTITUICAO', 'TED', 'TEF', 'DOC'), false);
$$;

create or replace function conta_antes_de_revisar(t transacoes_bancarias)
returns boolean language sql immutable as $$
  select not eh_parcelada(t) and (
    (t.tipo_conta = 'CREDIT' and t.sentido = 'despesa'
       and coalesce(t.tipo_operacao, '') not in ('PAGAMENTO_FATURA', 'TARIFA', 'ESTORNO', 'CASHBACK'))
    or (t.tipo_conta = 'BANK' and t.sentido = 'despesa'
        and t.tipo_operacao in ('CARTAO', 'ENCARGOS_JUROS_CHEQUE_ESPECIAL')
        and t.transferencia_propria is not true)
    -- Pix/transferencia com terceiro identificado, nos dois sentidos.
    or (eh_transferencia(t) and t.transferencia_propria = false)
    -- Entrada do proprio CPF ainda para revisar = sem par (o motor ja marcou
    -- as internas): veio de conta nao conectada.
    or (eh_transferencia(t) and t.transferencia_propria = true and t.sentido = 'receita')
  );
$$;

-- Motor: regra 0 (par de transferencia interna) antes das demais, e
-- releitura do estado no inicio de cada volta (o par marca uma linha que
-- ainda esta na fila desta mesma rodada).
create or replace function casar_transacoes_bancarias(uid uuid default null)
returns int language plpgsql security definer
set search_path = public, extensions as $$
declare
  u uuid := usuario_efetivo(uid);
  t transacoes_bancarias;
  par uuid;
  cand jsonb;
  n int;
  auto_ok boolean;
  ref_compra date;
  ciclo_t date;
  meio_t meio_pagamento;
  desc_t text;
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
    if (select estado from transacoes_bancarias where id = t.id) <> 'para_revisar' then
      continue;
    end if;
    cand := '[]'::jsonb;
    auto_ok := not t.bloquear_auto;
    meio_t := coalesce(t.meio_inferido, case when t.tipo_conta = 'CREDIT' then 'credito' else 'debito' end::meio_pagamento);
    ciclo_t := ciclo_caixa(t.data, meio_t, u);
    ref_compra := coalesce(t.data_compra_original, t.data);
    desc_t := normalizar_descricao(t.descricao);

    -- 0. Transferencia interna: o outro lado esta numa conta conectada.
    if eh_transferencia(t) and t.transferencia_propria = true and auto_ok then
      select q.id into par
      from transacoes_bancarias q
      where q.user_id = u and q.estado = 'para_revisar' and not q.bloquear_auto
        and q.id <> t.id and q.conta_pluggy_id <> t.conta_pluggy_id
        and eh_transferencia(q) and q.transferencia_propria = true
        and q.sentido <> t.sentido and q.valor = t.valor and abs(q.data - t.data) <= 1
      order by abs(q.data - t.data), q.data, q.id
      limit 1;
      if par is not null then
        perform _vincular(t.id, u, 'interna', par, true, null);
        perform _vincular(par, u, 'interna', t.id, true, null);
        casadas := casadas + 2;
        continue;
      end if;
    end if;

    -- 1. Liquidacao de fatura.
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

    -- 2. Parcelada: so parcelamento cadastrado.
    if eh_parcelada(t) then
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
      if n = 1 and auto_ok then
        select p.* into p_alvo
        from parcelamentos p
        where p.user_id = u and p.meio_pagamento = 'credito'
          and p.valor_parcela = t.valor and p.num_parcelas = t.parcela_total
          and abs(p.data_compra - coalesce(t.data_compra_original,
                (t.data - (coalesce(t.parcela_numero, 1) - 1) * interval '1 month')::date)) <= 5
          and not exists (
            select 1 from transacoes_bancarias o
            where o.user_id = u and o.vinculo_tipo = 'parcelamento' and o.vinculo_id = p.id
              and o.parcela_numero is not distinct from t.parcela_numero and o.id <> t.id);
        perform _vincular(t.id, u, 'parcelamento', p_alvo.id, true, null);
        casadas := casadas + 1;
        continue;
      end if;
      cand := cand || (
        select coalesce(jsonb_agg(jsonb_build_object('tipo', 'parcelamento', 'id', p.id,
                 'descricao', p.descricao, 'valor', p.valor_parcela)), '[]'::jsonb)
        from parcelamentos p
        where p.user_id = u and p.meio_pagamento = 'credito'
          and abs(p.valor_parcela - t.valor) <= t.valor * 0.05
          and p.num_parcelas = coalesce(t.parcela_total, p.num_parcelas));
      update transacoes_bancarias set candidatos = cand, atualizada_em = now()
       where id = t.id and user_id = u;
      continue;
    end if;

    -- 3. Recorrente nao estimado: valor exato, ou nome no banco com valor ate 20%.
    select count(*) into n
    from recorrentes r
    left join execucoes e on e.user_id = u and e.recorrente_id = r.id and e.ciclo = ciclo_t
    where r.user_id = u and r.ativo and not r.estimado and r.tipo = t.sentido
      and (r.meio_pagamento = 'credito') = (t.tipo_conta = 'CREDIT')
      and ciclo_caixa(r.data_inicio, r.meio_pagamento, u) <= ciclo_t
      and (r.data_fim is null or ciclo_t <= ciclo_caixa(r.data_fim, r.meio_pagamento, u))
      and (t.valor = coalesce(e.valor_realizado, r.valor_previsto)
           or (r.nome_banco = desc_t and t.valor between r.valor_previsto * 0.8 and r.valor_previsto * 1.2))
      and not exists (select 1 from transacoes_bancarias o
                      where o.user_id = u and o.vinculo_tipo = 'execucao' and o.vinculo_id = e.id);
    if n > 0 then
      select r.*, similarity(normalizar_descricao(r.descricao), desc_t) as sim,
             (r.nome_banco = desc_t) as pelo_nome
        into r_alvo
      from recorrentes r
      left join execucoes e on e.user_id = u and e.recorrente_id = r.id and e.ciclo = ciclo_t
      where r.user_id = u and r.ativo and not r.estimado and r.tipo = t.sentido
        and (r.meio_pagamento = 'credito') = (t.tipo_conta = 'CREDIT')
        and ciclo_caixa(r.data_inicio, r.meio_pagamento, u) <= ciclo_t
        and (r.data_fim is null or ciclo_t <= ciclo_caixa(r.data_fim, r.meio_pagamento, u))
        and (t.valor = coalesce(e.valor_realizado, r.valor_previsto)
             or (r.nome_banco = desc_t and t.valor between r.valor_previsto * 0.8 and r.valor_previsto * 1.2))
        and not exists (select 1 from transacoes_bancarias o
                        where o.user_id = u and o.vinculo_tipo = 'execucao' and o.vinculo_id = e.id)
      order by (r.nome_banco = desc_t) desc nulls last, sim desc
      limit 1;
      if n = 1 and auto_ok and (
           coalesce(r_alvo.pelo_nome, false)
           or r_alvo.sim >= 0.2
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
        where r.user_id = u and r.ativo and not r.estimado and r.tipo = t.sentido
          and (r.meio_pagamento = 'credito') = (t.tipo_conta = 'CREDIT')
          and ciclo_caixa(r.data_inicio, r.meio_pagamento, u) <= ciclo_t
          and (r.data_fim is null or ciclo_t <= ciclo_caixa(r.data_fim, r.meio_pagamento, u))
          and (t.valor = coalesce(e.valor_realizado, r.valor_previsto)
               or (r.nome_banco = desc_t and t.valor between r.valor_previsto * 0.8 and r.valor_previsto * 1.2))
          and not exists (select 1 from transacoes_bancarias o
                          where o.user_id = u and o.vinculo_tipo = 'execucao' and o.vinculo_id = e.id));
    end if;

    -- 4. Lancamento manual existente.
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
    cand := cand || (
      select coalesce(jsonb_agg(jsonb_build_object('tipo', 'avulso', 'id', a.id,
               'descricao', a.descricao, 'valor', a.valor, 'data', a.data)), '[]'::jsonb)
      from avulsos a
      where a.user_id = u and a.transacao_banco_id is null and a.tipo = t.sentido
        and (a.meio_pagamento = 'credito') = (t.tipo_conta = 'CREDIT')
        and abs(a.valor - t.valor) <= t.valor * 0.10 and abs(a.data - ref_compra) <= 3);

    -- 5. Sem casamento: sugestao de categoria pelas regras aprendidas.
    update transacoes_bancarias
       set candidatos = cand,
           categoria_sugerida_id = (
             select rc.categoria_id from regras_categoria rc
             where rc.user_id = u and rc.ativa and rc.confirmacoes >= 2
               and desc_t like rc.padrao || '%'
             order by length(rc.padrao) desc
             limit 1),
           atualizada_em = now()
     where id = t.id and user_id = u;
  end loop;

  return casadas;
end;
$$;

-- Desfazer uma interna desfaz o par inteiro (as duas pontas voltam a revisar).
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
  elsif t.vinculo_tipo = 'interna' then
    update transacoes_bancarias
       set estado = 'para_revisar', vinculo_tipo = null, vinculo_id = null,
           vinculo_automatico = false, bloquear_auto = true, atualizada_em = now()
     where id = t.vinculo_id and user_id = u and vinculo_tipo = 'interna';
  end if;

  update transacoes_bancarias
     set estado = 'para_revisar', vinculo_tipo = null, vinculo_id = null,
         vinculo_automatico = false, vinculo_anterior = null,
         bloquear_auto = true, atualizada_em = now()
   where id = t.id;
end;
$$;

-- "Ignorar todas para mim": saidas para o proprio CPF que sobraram sem par
-- (o usuario manda; cada uma fica em Revisadas com Desfazer). Devolve quantas.
create or replace function ignorar_transferencias_proprias()
returns int language plpgsql security definer
set search_path = public, extensions as $$
declare
  n int;
begin
  if auth.uid() is null then raise exception 'sessao obrigatoria'; end if;
  update transacoes_bancarias t
     set estado = 'ignorada', candidatos = '[]'::jsonb, atualizada_em = now()
   where t.user_id = auth.uid() and t.estado = 'para_revisar'
     and eh_transferencia(t) and t.transferencia_propria = true and t.sentido = 'despesa';
  get diagnostics n = row_count;
  return n;
end;
$$;

revoke execute on function ignorar_transferencias_proprias() from public, anon;
grant execute on function ignorar_transferencias_proprias() to authenticated;
grant execute on function eh_transferencia(transacoes_bancarias) to authenticated;

-- Contador do botao "Ignorar transferencias para mim" (todos os meses).
create or replace view v_resumo_banco with (security_invoker = true) as
select user_id,
       count(*) as itens_para_revisar,
       coalesce(sum(case when sentido = 'receita' then valor else -valor end)
                filter (where conta_no_saldo), 0) as valor_provisorio_no_saldo,
       coalesce(sum(case when sentido = 'receita' then valor else -valor end)
                filter (where not conta_no_saldo), 0) as valor_fora_do_saldo,
       count(*) filter (where transferencia_propria = true and sentido = 'despesa' and tipo_conta = 'BANK'
                          and tipo_operacao in ('PIX', 'TRANSFERENCIA_MESMA_INSTITUICAO', 'TED', 'TEF', 'DOC'))
         as saidas_proprias_sem_par
from v_para_revisar
group by user_id;
