-- Views (ESPECIFICACAO.md secao 7) -- o motor de calculo.
-- Todas com security_invoker = true: a view nunca amplia o que o RLS das
-- tabelas base ja permite para o usuario autenticado.

-- Expande cada parcelamento em uma linha por parcela (SQL dado literalmente
-- pela especificacao, secao 7 -- nao alterar).
create view v_parcelas with (security_invoker = true) as
select p.id as origem_id, 'parcelamento' as origem, p.user_id,
       p.descricao, p.categoria_id, p.meio_pagamento,
       n as numero_parcela, p.num_parcelas,
       p.valor_parcela as valor,
       (ciclo_caixa(p.data_compra, p.meio_pagamento)
         + (n - 1) * interval '1 month')::date as ciclo
from parcelamentos p
cross join lateral generate_series(1, p.num_parcelas) as n;

-- Expande recorrentes ativos por ciclo, aplicando execucoes quando houver.
-- Cada recorrencia tem uma ocorrencia por mes calendario (dia_referencia,
-- ajustado para o ultimo dia do mes quando o mes for mais curto); essa
-- ocorrencia entra no ciclo de caixa de acordo com o meio de pagamento
-- (um recorrente no credito desloca 1 ciclo, igual a uma compra avulsa).
-- O horizonte de geracao usa uma folga de 2 meses sobre horizonte_meses
-- porque o credito pode empurrar a ocorrencia para o ciclo seguinte; o
-- filtro final corta de volta exatamente no horizonte configurado.
create view v_recorrentes_ciclo with (security_invoker = true) as
select
  r.id as origem_id, 'recorrente' as origem, r.user_id,
  r.descricao, r.tipo, r.categoria_id, r.meio_pagamento, r.estimado,
  ciclo_caixa(occ.data_ocorrencia, r.meio_pagamento) as ciclo,
  coalesce(e.valor_realizado, r.valor_previsto) as valor,
  coalesce(e.status, 'previsto'::status_execucao) as status,
  e.data_efetiva
from recorrentes r
join config c on c.user_id = r.user_id
cross join lateral (
  select (mes + make_interval(days =>
           least(r.dia_referencia,
                 extract(day from (mes + interval '1 month - 1 day'))::int) - 1
         ))::date as data_ocorrencia
  from generate_series(
    date_trunc('month', r.data_inicio)::date,
    (date_trunc('month', current_date) + (c.horizonte_meses + 2) * interval '1 month')::date,
    interval '1 month'
  ) as mes
) occ
left join execucoes e
  on e.user_id = r.user_id
 and e.recorrente_id = r.id
 and e.ciclo = ciclo_caixa(occ.data_ocorrencia, r.meio_pagamento)
where r.ativo
  and (r.data_fim is null or occ.data_ocorrencia <= r.data_fim)
  and ciclo_caixa(occ.data_ocorrencia, r.meio_pagamento)
        <= (ciclo(current_date) + c.horizonte_meses * interval '1 month')::date;

-- Normaliza avulsos para o formato comum
create view v_avulsos with (security_invoker = true) as
select
  a.id as origem_id, 'avulso' as origem, a.user_id,
  a.descricao, a.tipo, a.categoria_id, a.meio_pagamento,
  ciclo_caixa(a.data, a.meio_pagamento) as ciclo,
  a.valor,
  'pago'::status_execucao as status,
  a.data as data_efetiva
from avulsos a;

-- Tabela-fato: uniao das tres origens de lancamento. E o que o Power BI consome.
-- Parcelamentos e avulsos nao passam por confirmacao por ciclo (ao contrario
-- dos recorrentes): sao lancados quando o fato ja ocorreu, por isso entram
-- como 'pago'. A descricao ganha o sufixo "(n/total)" so aqui, na saida --
-- nunca fica gravado em coluna (secao 6, "Colunas calculadas foram removidas").
create view v_fluxo with (security_invoker = true) as
select origem_id, origem, user_id,
       descricao || ' (' || numero_parcela || '/' || num_parcelas || ')' as descricao,
       'despesa'::tipo_lancamento as tipo,
       categoria_id, meio_pagamento, ciclo, valor,
       'pago'::status_execucao as status,
       null::date as data_efetiva
from v_parcelas
union all
select origem_id, origem, user_id, descricao, tipo, categoria_id, meio_pagamento,
       ciclo, valor, status, data_efetiva
from v_recorrentes_ciclo
union all
select origem_id, origem, user_id, descricao, tipo, categoria_id, meio_pagamento,
       ciclo, valor, status, data_efetiva
from v_avulsos;

-- Receitas, despesas, saldo do ciclo, previsto vs. realizado.
create view v_resumo_ciclo with (security_invoker = true) as
select
  user_id,
  ciclo,
  coalesce(sum(valor) filter (where tipo = 'receita'), 0) as receitas,
  coalesce(sum(valor) filter (where tipo = 'despesa'), 0) as despesas,
  coalesce(sum(valor) filter (where tipo = 'receita'), 0)
    - coalesce(sum(valor) filter (where tipo = 'despesa'), 0) as saldo,
  coalesce(sum(valor) filter (where tipo = 'receita' and status = 'pago'), 0) as receitas_realizadas,
  coalesce(sum(valor) filter (where tipo = 'receita' and status in ('previsto', 'pendente')), 0) as receitas_previstas,
  coalesce(sum(valor) filter (where tipo = 'despesa' and status = 'pago'), 0) as despesas_realizadas,
  coalesce(sum(valor) filter (where tipo = 'despesa' and status in ('previsto', 'pendente')), 0) as despesas_previstas
from v_fluxo
where status is distinct from 'cancelado'
group by user_id, ciclo;

-- Saldo acumulado projetado ao longo de horizonte_meses, ancorado na ultima
-- conciliacao registrada em `saldos` (secao 6). Sem uma conciliacao, nao ha
-- ponto de partida para projetar -- por isso o usuario que ainda nao
-- registrou nenhum saldo simplesmente nao aparece nesta view.
create view v_previsao with (security_invoker = true) as
with base as (
  select distinct on (s.user_id) s.user_id, s.ciclo as ciclo_base, s.valor_apurado
  from saldos s
  order by s.user_id, s.ciclo desc
),
horizonte as (
  select b.user_id, b.valor_apurado,
         (b.ciclo_base + n * interval '1 month')::date as ciclo
  from base b
  join config c on c.user_id = b.user_id
  cross join lateral generate_series(1, c.horizonte_meses) as n
)
select
  h.user_id,
  h.ciclo,
  h.valor_apurado + sum(coalesce(r.saldo, 0)) over (
    partition by h.user_id order by h.ciclo
  ) as saldo_projetado
from horizonte h
left join v_resumo_ciclo r on r.user_id = h.user_id and r.ciclo = h.ciclo;

-- Sinaliza saldo negativo previsto dentro do horizonte.
create view v_alertas with (security_invoker = true) as
select user_id, ciclo, saldo_projetado
from v_previsao
where saldo_projetado < 0;
