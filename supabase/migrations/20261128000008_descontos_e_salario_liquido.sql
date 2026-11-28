-- Descontos em folha nos calculos e salario casado pelo liquido
-- (ESPECIFICACAO.md 14.23, decisoes do usuario em 28/11/2026).
--
-- 1. BUG antigo: descontos_folha (INSS %, seguro, ...) era so cadastro --
--    nenhuma view o aplicava. A previsao contava o salario BRUTO inteiro
--    (~R$ 347/mes otimista). Agora cada desconto vira uma linha de despesa
--    (origem 'desconto', meio folha) em todo ciclo com salario de folha.
-- 2. O banco recebe o LIQUIDO. O motor casa o deposito com o salario pelo
--    liquido esperado (bruto - descontos - recorrentes de folha, ex. almoco),
--    com ate 10% de diferenca; e a diferenca (hora extra, reajuste) vai para o
--    bruto realizado do mes, de modo que bruto - descontos = liquido do banco
--    ao centavo e cada desconto continua visivel.
-- 3. O salario cai alguns dias antes do dia de recebimento do app (ex. pago em
--    29/10 com recebimento em 30/10): para casar, o ciclo do deposito e o de
--    data + 5 dias (o ciclo que ele financia).

alter table descontos_folha add column if not exists categoria_id uuid references categorias;
comment on column descontos_folha.categoria_id is
  'Opcional: categoria da linha de desconto (sem ela, conta no saldo mas nao aparece no ranking por categoria).';

-- Recorrentes de folha que sao despesa (ex. almoco descontado na folha),
-- ativos no ciclo: entram no liquido esperado.
create or replace function folha_despesas_no_ciclo(uid uuid, c date)
returns numeric language sql stable as $$
  select coalesce(sum(r.valor_previsto), 0)
  from recorrentes r
  where r.user_id = uid and r.ativo and r.tipo = 'despesa' and r.meio_pagamento = 'folha'
    and ciclo_caixa(r.data_inicio, r.meio_pagamento, uid) <= c
    and (r.data_fim is null or c <= ciclo_caixa(r.data_fim, r.meio_pagamento, uid));
$$;

-- Soma dos descontos sobre um bruto (cada percentual arredondado ao centavo,
-- igual a linha que aparece no fluxo).
create or replace function descontos_sobre(uid uuid, bruto numeric)
returns numeric language sql stable as $$
  select coalesce(sum(coalesce(d.valor_fixo, round(bruto * d.percentual / 100, 2))), 0)
  from descontos_folha d
  where d.user_id = uid and d.ativo;
$$;

create or replace function liquido_esperado(uid uuid, bruto numeric, c date)
returns numeric language sql stable as $$
  select bruto - descontos_sobre(uid, bruto) - folha_despesas_no_ciclo(uid, c);
$$;

-- Bruto que, menos os descontos e os recorrentes de folha, da exatamente o
-- liquido recebido: liquido = B - pct*B - fixos  =>  B = (liquido + fixos)/(1 - pct).
-- O resultado final soma os descontos ja arredondados, para fechar no centavo.
create or replace function bruto_do_liquido(uid uuid, liquido numeric, c date)
returns numeric language plpgsql stable as $$
declare
  pct numeric;
  fixos numeric;
  b numeric;
begin
  select coalesce(sum(d.percentual), 0), coalesce(sum(d.valor_fixo), 0)
    into pct, fixos
  from descontos_folha d where d.user_id = uid and d.ativo;
  fixos := fixos + folha_despesas_no_ciclo(uid, c);
  b := (liquido + fixos) / (1 - pct / 100);
  return liquido + folha_despesas_no_ciclo(uid, c) + descontos_sobre(uid, b);
end;
$$;

-- Execucao paga a partir do banco: salario de folha guarda o BRUTO equivalente
-- ao liquido recebido (item 2); o resto guarda o valor do banco, como antes.
create or replace function _pagar_execucao(t_id uuid, uid uuid, rec_id uuid, c date, valor numeric, d date, automatico boolean)
returns uuid language plpgsql security definer
set search_path = public, extensions as $$
declare
  anterior jsonb;
  exec_id uuid;
  realizado numeric := valor;
begin
  if exists (select 1 from recorrentes r
             where r.id = rec_id and r.user_id = uid and r.tipo = 'receita' and r.meio_pagamento = 'folha') then
    realizado := bruto_do_liquido(uid, valor, c);
  end if;

  select to_jsonb(e) into anterior
  from execucoes e
  where e.user_id = uid and e.recorrente_id = rec_id and e.ciclo = c;

  insert into execucoes (user_id, ciclo, recorrente_id, valor_realizado, status, data_efetiva)
  values (uid, c, rec_id, realizado, 'pago', d)
  on conflict (user_id, ciclo, recorrente_id)
  do update set status = 'pago', valor_realizado = excluded.valor_realizado,
                data_efetiva = excluded.data_efetiva
  returning id into exec_id;

  perform _vincular(t_id, uid, 'execucao', exec_id, automatico, anterior);
  return exec_id;
end;
$$;

-- Linhas de desconto por ciclo: uma por desconto ativo, em cada ciclo com
-- salario de folha (receita), sobre o bruto daquele ciclo (realizado, se o
-- salario ja casou; senao, previsto). Mesmo formato dos ramos de v_fluxo.
create or replace view v_descontos_ciclo with (security_invoker = true) as
select d.id as origem_id,
       'desconto'::text as origem,
       s.user_id,
       d.descricao,
       'despesa'::tipo_lancamento as tipo,
       d.categoria_id,
       'folha'::meio_pagamento as meio_pagamento,
       s.ciclo,
       coalesce(d.valor_fixo, round(s.valor * d.percentual / 100, 2))::numeric(12,2) as valor,
       s.status,
       s.data_efetiva,
       coalesce(cat.nome, 'Descontos em folha') as categoria_nome,
       null::date as data_compra,
       null::smallint as dia_referencia
from v_recorrentes_ciclo s
join descontos_folha d on d.user_id = s.user_id and d.ativo
left join categorias cat on cat.id = d.categoria_id
where s.tipo = 'receita' and s.meio_pagamento = 'folha'
  and s.status is distinct from 'cancelado';

create or replace view v_fluxo with (security_invoker = true) as
select f.origem_id, f.origem, f.user_id, f.descricao, f.tipo, f.categoria_id,
       f.meio_pagamento, f.ciclo, f.valor, f.status, f.data_efetiva,
       f.categoria_nome, f.data_compra, f.dia_referencia,
       case when f.meio_pagamento = 'credito'
            then fatura_vencimento_no_ciclo(f.ciclo, f.user_id)
       end as fatura_vencimento,
       case
         when f.meio_pagamento = 'credito' then fatura_vencimento_no_ciclo(f.ciclo, f.user_id)
         when f.data_efetiva is not null then f.data_efetiva
         when f.meio_pagamento = 'folha' then ciclo_inicio(f.ciclo)
         when f.origem = 'parcelamento' then dia_no_ciclo(f.ciclo, extract(day from f.data_compra)::int)
         when f.dia_referencia is not null then dia_no_ciclo(f.ciclo, f.dia_referencia)
       end as data_caixa,
       f.provisorio
from (
  select origem_id, origem, user_id,
         descricao || ' (' || numero_parcela || '/' || num_parcelas || ')' as descricao,
         'despesa'::tipo_lancamento as tipo,
         categoria_id, meio_pagamento, ciclo, valor,
         'pago'::status_execucao as status,
         null::date as data_efetiva,
         categoria_nome,
         data_compra,
         null::smallint as dia_referencia,
         false as provisorio
  from v_parcelas
  union all
  select origem_id, origem, user_id, descricao, tipo, categoria_id, meio_pagamento,
         ciclo, valor, status, data_efetiva, categoria_nome,
         null::date as data_compra,
         dia_referencia,
         false
  from v_recorrentes_ciclo
  union all
  select origem_id, origem, user_id, descricao, tipo, categoria_id, meio_pagamento,
         ciclo, valor, status, data_efetiva, categoria_nome,
         null::date as data_compra,
         null::smallint as dia_referencia,
         false
  from v_avulsos
  union all
  select origem_id, origem, user_id, descricao, tipo, categoria_id, meio_pagamento,
         ciclo, valor, status, data_efetiva, categoria_nome, data_compra, dia_referencia,
         false
  from v_descontos_ciclo
  union all
  select origem_id, origem, user_id, descricao, tipo, categoria_id, meio_pagamento,
         ciclo, valor, status, data_efetiva, categoria_nome, data_compra, dia_referencia,
         true
  from v_banco_provisorio
) f;

revoke all on v_descontos_ciclo from anon;
grant select on v_descontos_ciclo to authenticated;
grant execute on function folha_despesas_no_ciclo(uuid, date), descontos_sobre(uuid, numeric),
  liquido_esperado(uuid, numeric, date), bruto_do_liquido(uuid, numeric, date) to authenticated;

-- Motor (mesmo de 20261128000007) com o passo 2b do salario liquido.
create or replace function casar_transacoes_bancarias(uid uuid default null)
returns int language plpgsql security definer
set search_path = public, extensions as $$
declare
  u uuid := usuario_efetivo(uid);
  t transacoes_bancarias;
  par uuid;
  ciclo_sal date;
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

    -- 2b. Salario de folha (14.23): o banco traz o LIQUIDO. Casa com o
    -- recorrente de salario pelo liquido esperado (ate 10%) ou pelo nome no
    -- banco ja aprendido; o ciclo e o de data + 5 dias (o salario cai alguns
    -- dias antes do dia de recebimento do app). O bruto do mes e recalculado
    -- em _pagar_execucao.
    if t.tipo_conta = 'BANK' and t.sentido = 'receita' and t.transferencia_propria is not true then
      ciclo_sal := ciclo((t.data + 5)::date);
      select count(*) into n
      from recorrentes r
      left join execucoes e on e.user_id = u and e.recorrente_id = r.id and e.ciclo = ciclo_sal
      where r.user_id = u and r.ativo and not r.estimado and r.tipo = 'receita' and r.meio_pagamento = 'folha'
        and ciclo_caixa(r.data_inicio, r.meio_pagamento, u) <= ciclo_sal
        and (r.data_fim is null or ciclo_sal <= ciclo_caixa(r.data_fim, r.meio_pagamento, u))
        and (abs(t.valor - liquido_esperado(u, r.valor_previsto, ciclo_sal))
               <= liquido_esperado(u, r.valor_previsto, ciclo_sal) * 0.10
             or r.nome_banco = desc_t)
        and not exists (select 1 from transacoes_bancarias o
                        where o.user_id = u and o.vinculo_tipo = 'execucao' and o.vinculo_id = e.id);
      if n = 1 and auto_ok and (t.tipo_operacao = 'FOLHA_PAGAMENTO' or exists (
            select 1 from recorrentes r where r.user_id = u and r.meio_pagamento = 'folha'
              and r.tipo = 'receita' and r.nome_banco = desc_t)) then
        select r.* into r_alvo
        from recorrentes r
        left join execucoes e on e.user_id = u and e.recorrente_id = r.id and e.ciclo = ciclo_sal
        where r.user_id = u and r.ativo and not r.estimado and r.tipo = 'receita' and r.meio_pagamento = 'folha'
          and ciclo_caixa(r.data_inicio, r.meio_pagamento, u) <= ciclo_sal
          and (r.data_fim is null or ciclo_sal <= ciclo_caixa(r.data_fim, r.meio_pagamento, u))
          and (abs(t.valor - liquido_esperado(u, r.valor_previsto, ciclo_sal))
                 <= liquido_esperado(u, r.valor_previsto, ciclo_sal) * 0.10
               or r.nome_banco = desc_t)
          and not exists (select 1 from transacoes_bancarias o
                          where o.user_id = u and o.vinculo_tipo = 'execucao' and o.vinculo_id = e.id);
        perform _pagar_execucao(t.id, u, r_alvo.id, ciclo_sal, t.valor, t.data, true);
        casadas := casadas + 1;
        continue;
      end if;
      -- Hora extra grande, 13o etc.: vira sugestao (ate 40% de diferenca).
      cand := cand || (
        select coalesce(jsonb_agg(jsonb_build_object('tipo', 'recorrente', 'id', r.id, 'ciclo', ciclo_sal,
                 'descricao', r.descricao || ' (liquido esperado ' ||
                   to_char(liquido_esperado(u, r.valor_previsto, ciclo_sal), 'FM999G990D00') || ')',
                 'valor', r.valor_previsto)), '[]'::jsonb)
        from recorrentes r
        left join execucoes e on e.user_id = u and e.recorrente_id = r.id and e.ciclo = ciclo_sal
        where r.user_id = u and r.ativo and not r.estimado and r.tipo = 'receita' and r.meio_pagamento = 'folha'
          and ciclo_caixa(r.data_inicio, r.meio_pagamento, u) <= ciclo_sal
          and (r.data_fim is null or ciclo_sal <= ciclo_caixa(r.data_fim, r.meio_pagamento, u))
          and abs(t.valor - liquido_esperado(u, r.valor_previsto, ciclo_sal))
                <= liquido_esperado(u, r.valor_previsto, ciclo_sal) * 0.40
          and not exists (select 1 from transacoes_bancarias o
                          where o.user_id = u and o.vinculo_tipo = 'execucao' and o.vinculo_id = e.id));
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
