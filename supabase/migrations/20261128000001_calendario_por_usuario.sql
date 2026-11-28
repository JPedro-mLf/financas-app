-- Funcoes de calendario passam a ler a config DE UM USUARIO EXPLICITO.
--
-- fatura_fecha/fatura_vence/fatura_vencimento_no_ciclo faziam `from config`
-- sem filtro e dependiam do RLS para enxergar so a linha do usuario logado.
-- Sem RLS -- role postgres nos testes, `security definer`, e as Edge Functions
-- da integracao Open Finance (service_role, sem usuario logado; secao 14.8) --
-- a funcao pegava QUALQUER linha de config. Apareceu no teste 04 rodando no
-- projeto v2, que tem a config real do usuario: vencimento dia 4 em vez de 3.
--
-- Agora cada funcao tem uma versao com `uid` explicito, e as views passam o
-- dono da linha. As versoes antigas (sem uid) continuam existindo -- o app as
-- chama por RPC -- e usam o usuario logado (auth.uid()), o mesmo resultado de
-- antes para o app; sem sessao, devolvem nulo em vez de um valor arbitrario.

create or replace function fatura_fecha(compra date, uid uuid)
returns date language sql stable as $$
  select case when extract(day from compra) <= c.dia_fechamento
              then  date_trunc('month', compra)::date + (c.dia_fechamento - 1)
              else (date_trunc('month', compra) + interval '1 month')::date
                     + (c.dia_fechamento - 1)
         end
  from config c
  where c.user_id = uid;
$$;

create or replace function fatura_vence(compra date, uid uuid)
returns date language sql stable as $$
  select (date_trunc('month', fatura_fecha(compra, uid)) + interval '1 month')::date
         + (c.dia_vencimento - 1)
  from config c
  where c.user_id = uid;
$$;

create or replace function ciclo_caixa(d date, meio meio_pagamento, uid uuid)
returns date language sql stable as $$
  select case when meio = 'credito' then ciclo(fatura_vence(d, uid))
              else ciclo(d) end;
$$;

create or replace function fatura_vencimento_no_ciclo(c date, uid uuid)
returns date language sql stable as $$
  select date_trunc('month', c)::date + (cfg.dia_vencimento - 1)
  from config cfg
  where cfg.user_id = uid;
$$;

-- Versoes sem uid: usuario logado.
create or replace function fatura_fecha(compra date)
returns date language sql stable as $$
  select fatura_fecha(compra, auth.uid());
$$;

create or replace function fatura_vence(compra date)
returns date language sql stable as $$
  select fatura_vence(compra, auth.uid());
$$;

create or replace function ciclo_caixa(d date, meio meio_pagamento)
returns date language sql stable as $$
  select ciclo_caixa(d, meio, auth.uid());
$$;

create or replace function fatura_vencimento_no_ciclo(c date)
returns date language sql stable as $$
  select fatura_vencimento_no_ciclo(c, auth.uid());
$$;

grant execute on function fatura_fecha(date, uuid) to authenticated;
grant execute on function fatura_vence(date, uuid) to authenticated;
grant execute on function ciclo_caixa(date, meio_pagamento, uuid) to authenticated;
grant execute on function fatura_vencimento_no_ciclo(date, uuid) to authenticated;

-- Views: mesmas colunas, mesma ordem; so passam o dono da linha.
create or replace view v_parcelas with (security_invoker = true) as
select p.id as origem_id,
       'parcelamento'::text as origem,
       p.user_id,
       p.descricao,
       p.categoria_id,
       p.meio_pagamento,
       n.n as numero_parcela,
       p.num_parcelas,
       p.valor_parcela as valor,
       (ciclo_caixa(p.data_compra, p.meio_pagamento, p.user_id) + (n.n - 1) * interval '1 month')::date as ciclo,
       cat.nome as categoria_nome,
       p.data_compra
from parcelamentos p
join categorias cat on cat.id = p.categoria_id
cross join lateral generate_series(1, p.num_parcelas::integer) n(n);

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
       coalesce(e.valor_realizado, r.valor_previsto) as valor,
       coalesce(e.status, 'previsto'::status_execucao) as status,
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
where r.ativo
  and (r.data_fim is null or gs.ciclo::date <= ciclo_caixa(r.data_fim, r.meio_pagamento, r.user_id));

create or replace view v_avulsos with (security_invoker = true) as
select a.id as origem_id,
       'avulso'::text as origem,
       a.user_id,
       a.descricao,
       a.tipo,
       a.categoria_id,
       a.meio_pagamento,
       ciclo_caixa(a.data, a.meio_pagamento, a.user_id) as ciclo,
       a.valor,
       'pago'::status_execucao as status,
       a.data as data_efetiva,
       cat.nome as categoria_nome
from avulsos a
join categorias cat on cat.id = a.categoria_id;

create or replace view v_fluxo with (security_invoker = true) as
select f.*,
       case when f.meio_pagamento = 'credito'
            then fatura_vencimento_no_ciclo(f.ciclo, f.user_id)
       end as fatura_vencimento,
       case
         when f.meio_pagamento = 'credito' then fatura_vencimento_no_ciclo(f.ciclo, f.user_id)
         when f.data_efetiva is not null then f.data_efetiva
         when f.meio_pagamento = 'folha' then ciclo_inicio(f.ciclo)
         when f.origem = 'parcelamento' then dia_no_ciclo(f.ciclo, extract(day from f.data_compra)::int)
         when f.dia_referencia is not null then dia_no_ciclo(f.ciclo, f.dia_referencia)
       end as data_caixa
from (
  select origem_id, origem, user_id,
         descricao || ' (' || numero_parcela || '/' || num_parcelas || ')' as descricao,
         'despesa'::tipo_lancamento as tipo,
         categoria_id, meio_pagamento, ciclo, valor,
         'pago'::status_execucao as status,
         null::date as data_efetiva,
         categoria_nome,
         data_compra,
         null::smallint as dia_referencia
  from v_parcelas
  union all
  select origem_id, origem, user_id, descricao, tipo, categoria_id, meio_pagamento,
         ciclo, valor, status, data_efetiva, categoria_nome,
         null::date as data_compra,
         dia_referencia
  from v_recorrentes_ciclo
  union all
  select origem_id, origem, user_id, descricao, tipo, categoria_id, meio_pagamento,
         ciclo, valor, status, data_efetiva, categoria_nome,
         null::date as data_compra,
         null::smallint as dia_referencia
  from v_avulsos
) f;
