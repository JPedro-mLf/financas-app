-- Ajustes da revisao com dados reais (ESPECIFICACAO.md 14.21, decisoes do
-- usuario em 28/11/2026):
--   1. Parceladas vindas do banco NAO contam no saldo: os parcelamentos
--      cadastrados a mao sao a fonte. Ficam num filtro proprio so para conferir.
--   2. Recorrente memoriza o "nome no banco" (nome_banco) no primeiro vinculo
--      manual; dai em diante casa sozinho por esse nome, com tolerancia de valor
--      (reajuste, cambio). Caso real: Apple cadastrada 19,99, cobrada 19,90,
--      descrita "APPLE.COM/BILL".
--   3. Recorrente estimado vira ENVELOPE da sua categoria: no ciclo atual e nos
--      futuros conta so o que falta gastar (previsto - gasto real da categoria no
--      ciclo); ciclo que ja passou sem execucao: zera (status cancelado).
--   4. Pix/transferencia com terceiro identificado conta no saldo na hora;
--      transferencia propria nao. transferencia_propria passa a ter 3 estados:
--      true (para si), false (terceiro identificado), null (desconhecido: sem
--      OWNER_CPF ou sem documento) -- desconhecido continua fora do saldo.

alter table transacoes_bancarias add column if not exists tipo_pagamento text;  -- SINGLE | INSTALLMENT (cartao)
alter table transacoes_bancarias alter column transferencia_propria drop not null;
alter table transacoes_bancarias alter column transferencia_propria drop default;
-- Ate agora nenhuma sincronizacao teve OWNER_CPF: "false" significava
-- "nao verificado". Passa a ser desconhecido.
update transacoes_bancarias set transferencia_propria = null where transferencia_propria = false;

alter table recorrentes add column if not exists nome_banco text;
comment on column recorrentes.nome_banco is
  'Descricao normalizada com que o banco mostra este recorrente (aprendida no primeiro vinculo manual na tela Revisar).';

-- Parcela escrita so no texto ("SERGIO S 6/10"): numero e total.
create or replace function parcela_do_texto(descricao text, out numero int, out total int)
language sql immutable as $$
  select m[1]::int, m[2]::int
  from (select regexp_match(coalesce(descricao, ''), '(?:^|\D)(\d{1,2})/(\d{1,2})(?:\D|$)') as m) x
  where m is not null and m[2]::int between 2 and 48 and m[1]::int between 1 and m[2]::int;
$$;

-- Completa as parcelas que so vieram no texto (a ingestao passa a fazer o mesmo).
update transacoes_bancarias
   set parcela_numero = (parcela_do_texto(descricao)).numero,
       parcela_total = (parcela_do_texto(descricao)).total
 where tipo_conta = 'CREDIT' and coalesce(parcela_total, 0) <= 1
   and (parcela_do_texto(descricao)).total is not null;

create or replace function eh_parcelada(t transacoes_bancarias)
returns boolean language sql immutable as $$
  -- coalesce: campo vazio daria NULL e contaminaria toda regra que usa esta.
  select coalesce(t.tipo_conta = 'CREDIT'
     and (coalesce(t.parcela_total, 0) > 1 or coalesce(t.tipo_pagamento, '') = 'INSTALLMENT'), false);
$$;

-- Quem conta antes de revisado (substitui elegivel_provisorio).
create or replace function conta_antes_de_revisar(t transacoes_bancarias)
returns boolean language sql immutable as $$
  -- Transferencia para si mesmo nunca conta, de nenhum tipo.
  select not eh_parcelada(t) and t.transferencia_propria is not true and (
    (t.tipo_conta = 'CREDIT' and t.sentido = 'despesa'
       and coalesce(t.tipo_operacao, '') not in ('PAGAMENTO_FATURA', 'TARIFA', 'ESTORNO', 'CASHBACK'))
    or (t.tipo_conta = 'BANK' and t.sentido = 'despesa' and t.tipo_operacao = 'CARTAO')
    -- Pix/transferencia com terceiro identificado, nos dois sentidos.
    or (t.tipo_conta = 'BANK'
        and t.tipo_operacao in ('PIX', 'TRANSFERENCIA_MESMA_INSTITUICAO', 'TED', 'TEF', 'DOC')
        and t.transferencia_propria = false)
  );
$$;

create or replace view v_banco_provisorio with (security_invoker = true) as
select t.id as origem_id,
       'banco'::text as origem,
       t.user_id,
       t.descricao,
       t.sentido as tipo,
       t.categoria_sugerida_id as categoria_id,
       coalesce(t.meio_inferido,
                case when t.tipo_conta = 'CREDIT' then 'credito' else 'debito' end::meio_pagamento) as meio_pagamento,
       ciclo_caixa(t.data,
                   coalesce(t.meio_inferido,
                            case when t.tipo_conta = 'CREDIT' then 'credito' else 'debito' end::meio_pagamento),
                   t.user_id) as ciclo,
       t.valor,
       'pago'::status_execucao as status,
       t.data as data_efetiva,
       cat.nome as categoria_nome,
       t.data_compra_original as data_compra,
       null::smallint as dia_referencia
from transacoes_bancarias t
left join categorias cat on cat.id = t.categoria_sugerida_id
where t.estado = 'para_revisar'
  and t.candidatos = '[]'::jsonb
  and conta_antes_de_revisar(t);

-- Envelope dos estimados (item 3). Mesmas colunas e ordem de antes.
create or replace view v_recorrentes_ciclo with (security_invoker = true) as
select r.id as origem_id,
       'recorrente'::text as origem,
       r.user_id,
       r.descricao,
       r.tipo,
       r.categoria_id,
       r.meio_pagamento,
       r.estimado,
       gs.ciclo::date as ciclo,
       (case
         when e.id is not null then coalesce(e.valor_realizado, r.valor_previsto)
         when r.estimado and gs.ciclo::date < ciclo(current_date) then 0
         when r.estimado and r.tipo = 'despesa' then greatest(r.valor_previsto - coalesce(g.gasto, 0), 0)
         else r.valor_previsto
       end)::numeric(12,2) as valor,
       case
         when e.id is not null then e.status
         when r.estimado and gs.ciclo::date < ciclo(current_date) then 'cancelado'::status_execucao
         else 'previsto'::status_execucao
       end as status,
       e.data_efetiva,
       cat.nome as categoria_nome,
       r.dia_referencia
from recorrentes r
join config c on c.user_id = r.user_id
join categorias cat on cat.id = r.categoria_id
cross join lateral generate_series(
  ciclo_caixa(r.data_inicio, r.meio_pagamento, r.user_id),
  (ciclo(current_date) + c.horizonte_meses * interval '1 month')::date,
  interval '1 month'
) as gs(ciclo)
left join execucoes e
  on e.user_id = r.user_id
 and e.recorrente_id = r.id
 and e.ciclo = gs.ciclo::date
-- Gasto real da categoria no ciclo, fora os recorrentes: lancamentos,
-- parcelas e compras do banco ainda nao revisadas (com categoria sugerida).
left join lateral (
  select sum(x.valor) as gasto
  from (
    select a.valor from v_avulsos a
     where r.estimado and a.user_id = r.user_id and a.ciclo = gs.ciclo::date
       and a.categoria_id = r.categoria_id and a.tipo = 'despesa'
    union all
    select p.valor from v_parcelas p
     where r.estimado and p.user_id = r.user_id and p.ciclo = gs.ciclo::date
       and p.categoria_id = r.categoria_id
    union all
    select b.valor from v_banco_provisorio b
     where r.estimado and b.user_id = r.user_id and b.ciclo = gs.ciclo::date
       and b.categoria_id = r.categoria_id and b.tipo = 'despesa'
  ) x
) g on true
where r.ativo
  and (r.data_fim is null or gs.ciclo::date <= ciclo_caixa(r.data_fim, r.meio_pagamento, r.user_id));

-- v_para_revisar: parceladas saem desta lista (tem a propria, abaixo) e
-- conta_no_saldo segue a regra nova. Colunas novas no fim.
create or replace view v_para_revisar with (security_invoker = true) as
select t.id, t.user_id, t.data, t.valor, t.sentido, t.descricao,
       t.tipo_conta, t.tipo_operacao, t.meio_inferido,
       t.parcela_numero, t.parcela_total, t.data_compra_original,
       t.transferencia_propria, t.candidatos,
       t.categoria_sugerida_id, cat.nome as categoria_sugerida_nome,
       c.banco,
       ciclo_caixa(t.data,
                   coalesce(t.meio_inferido,
                            case when t.tipo_conta = 'CREDIT' then 'credito' else 'debito' end::meio_pagamento),
                   t.user_id) as ciclo,
       (t.candidatos = '[]'::jsonb and conta_antes_de_revisar(t)) as conta_no_saldo
from transacoes_bancarias t
left join categorias cat on cat.id = t.categoria_sugerida_id
left join contas_pluggy c on c.user_id = t.user_id and c.conta_pluggy_id = t.conta_pluggy_id
where t.estado = 'para_revisar'
  and not eh_parcelada(t);

-- Filtro "Parceladas": so conferencia. Nunca contam no saldo por aqui.
create or replace view v_parceladas_banco with (security_invoker = true) as
select t.id, t.user_id, t.data, t.valor, t.descricao, t.estado,
       t.parcela_numero, t.parcela_total, c.banco,
       ciclo_caixa(t.data, 'credito', t.user_id) as ciclo,
       p.descricao as parcelamento_descricao,
       p.valor_parcela as parcelamento_valor,
       p.num_parcelas as parcelamento_total,
       case when t.vinculo_tipo = 'parcelamento' then 'confere'
            when t.estado = 'ignorada' then 'ignorada'
            else 'sem_cadastro' end as situacao,
       t.candidatos
from transacoes_bancarias t
left join contas_pluggy c on c.user_id = t.user_id and c.conta_pluggy_id = t.conta_pluggy_id
left join parcelamentos p on t.vinculo_tipo = 'parcelamento' and p.id = t.vinculo_id
where eh_parcelada(t)
  and t.estado in ('para_revisar', 'vinculada', 'ignorada');

drop function if exists elegivel_provisorio(text, tipo_lancamento, text);

-- O motor (mesmo da migration 20261128000003), com:
--   - parceladas: so a regra 2 (parcelamento cadastrado); nunca casam com
--     recorrente nem com lancamento avulso;
--   - recorrentes: estimados ficam fora (sao envelope); casa tambem pelo
--     nome_banco aprendido, com valor ate 20% diferente.
create or replace function casar_transacoes_bancarias(uid uuid default null)
returns int language plpgsql security definer
set search_path = public, extensions as $$
declare
  u uuid := usuario_efetivo(uid);
  t transacoes_bancarias;
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
    cand := '[]'::jsonb;
    auto_ok := not t.bloquear_auto;
    meio_t := coalesce(t.meio_inferido, case when t.tipo_conta = 'CREDIT' then 'credito' else 'debito' end::meio_pagamento);
    ciclo_t := ciclo_caixa(t.data, meio_t, u);
    ref_compra := coalesce(t.data_compra_original, t.data);
    desc_t := normalizar_descricao(t.descricao);

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

    -- 2. Parcelada: so parcelamento cadastrado. Sem cadastro, fica para
    -- conferencia (fora do saldo) e nao passa pelas demais regras.
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

    -- 3. Recorrente nao estimado esperado no ciclo: valor exato, ou nome no
    -- banco ja aprendido com valor ate 20% diferente.
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

-- Vincular a um recorrente ensina o nome no banco (item 2).
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
    update recorrentes set nome_banco = normalizar_descricao(t.descricao)
     where id = p_alvo and user_id = u;
  elsif p_tipo = 'liquidacao' then
    perform _vincular(t.id, u, 'liquidacao', null, false, null);
  else
    raise exception 'tipo de vinculo invalido: %', p_tipo;
  end if;
end;
$$;

revoke all on v_parceladas_banco from anon;
grant select on v_parceladas_banco to authenticated;
grant execute on function eh_parcelada(transacoes_bancarias), conta_antes_de_revisar(transacoes_bancarias),
  parcela_do_texto(text) to authenticated;
