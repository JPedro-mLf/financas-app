-- Juros de cheque especial na projecao (ESPECIFICACAO.md secao 7).
--
-- Quando o saldo acumulado termina um ciclo negativo, o banco cobra juros
-- sobre o valor negativado no ciclo seguinte. A previsao passa a cobrar isso:
--
--   juros(C)     = taxa * max(0, -acumulado(C-1))
--   acumulado(C) = acumulado(C-1) + saldo(C) - juros(C)
--
-- So vale para ciclos FUTUROS (depois do ciclo atual e da ancora de `saldos`):
-- o que ja aconteceu e realizado, e o juro cobrado de verdade entra como
-- lancamento real. Como cada ciclo passa a depender do anterior, a soma-prefixo
-- da versao original vira uma recursao nos ciclos futuros; os anteriores
-- continuam pela soma-prefixo, que da exatamente o mesmo valor de antes.
--
-- Aproximacao assumida: olha o saldo no FIM de cada ciclo. Negativo so no meio
-- do mes (antes do salario) nao gera juros aqui.

alter table config
  add column taxa_cheque_especial numeric(7,5) not null default 0.08965
    check (taxa_cheque_especial >= 0 and taxa_cheque_especial <= 1);

comment on column config.taxa_cheque_especial is
  'Taxa mensal do cheque especial (fracao: 0.08965 = 8,965% a.m., juros + IOF), aplicada na projecao sobre saldo acumulado negativo.';

create or replace view v_saldo_acumulado with (security_invoker = true) as
with recursive ancora as (
  select distinct on (s.user_id) s.user_id, s.ciclo as ciclo_ancora, s.valor_apurado
  from saldos s
  order by s.user_id, s.ciclo desc
),
janela as (
  select a.user_id, a.ciclo_ancora, a.valor_apurado, c.horizonte_meses,
         c.taxa_cheque_especial as taxa,
         -- A partir deste ciclo (exclusive) a projecao cobra juros.
         greatest(a.ciclo_ancora, ciclo(current_date)) as corte,
         coalesce(
           (select min(f.ciclo) from v_fluxo f where f.user_id = a.user_id),
           a.ciclo_ancora
         ) as inicio
  from ancora a
  join config c on c.user_id = a.user_id
),
ciclos as (
  select j.user_id, j.ciclo_ancora, j.valor_apurado, j.taxa, j.corte,
         gs.ciclo::date as ciclo
  from janela j
  cross join lateral generate_series(
    least(j.ciclo_ancora, j.inicio),
    (j.corte + j.horizonte_meses * interval '1 month')::date,
    interval '1 month'
  ) as gs(ciclo)
),
com_prefixo as (
  select c.user_id, c.ciclo_ancora, c.valor_apurado, c.taxa, c.corte, c.ciclo,
         coalesce(r.saldo, 0) as saldo_ciclo,
         sum(coalesce(r.saldo, 0)) over (partition by c.user_id order by c.ciclo) as prefixo
  from ciclos c
  left join v_resumo_ciclo r on r.user_id = c.user_id and r.ciclo = c.ciclo
),
prefixo_ancora as (
  select user_id, prefixo as prefixo_no_ancora from com_prefixo where ciclo = ciclo_ancora
),
sem_juros as (
  select cp.user_id, cp.ciclo, cp.taxa, cp.corte, cp.saldo_ciclo,
         cp.valor_apurado + cp.prefixo - pa.prefixo_no_ancora as acumulado
  from com_prefixo cp
  join prefixo_ancora pa on pa.user_id = cp.user_id
),
projecao as (
  -- Ponto de partida: o ciclo de corte, sem juros (ainda e presente/passado).
  select s.user_id, s.ciclo, s.taxa, s.acumulado, 0::numeric as juros
  from sem_juros s
  where s.ciclo = s.corte
  union all
  select p.user_id, n.ciclo, p.taxa,
         p.acumulado + n.saldo_ciclo - j.juros,
         j.juros
  from projecao p
  join sem_juros n
    on n.user_id = p.user_id
   and n.ciclo = (p.ciclo + interval '1 month')::date
  cross join lateral (
    select case when p.acumulado < 0 then round(-p.acumulado * p.taxa, 2) else 0 end as juros
  ) j
)
select user_id, ciclo, acumulado as saldo_acumulado, 0::numeric as juros_cheque_especial
from sem_juros
where ciclo < corte
union all
select user_id, ciclo, acumulado, juros
from projecao;

-- v_previsao passa a ler de v_saldo_acumulado: uma unica regra de projecao,
-- e os dois numeros (Resumo mes a mes e lista da previsao/alertas) nunca
-- divergem. Mesmos ciclos de antes: os `horizonte_meses` seguintes a ancora.
create or replace view v_previsao with (security_invoker = true) as
with base as (
  select distinct on (s.user_id) s.user_id, s.ciclo as ciclo_base
  from saldos s
  order by s.user_id, s.ciclo desc
),
horizonte as (
  select b.user_id, (b.ciclo_base + n * interval '1 month')::date as ciclo
  from base b
  join config c on c.user_id = b.user_id
  cross join lateral generate_series(1, c.horizonte_meses) as n
)
select h.user_id, h.ciclo, a.saldo_acumulado as saldo_projetado,
       a.juros_cheque_especial
from horizonte h
join v_saldo_acumulado a on a.user_id = h.user_id and a.ciclo = h.ciclo;
