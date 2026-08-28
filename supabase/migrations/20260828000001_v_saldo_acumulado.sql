-- Saldo acumulado ate qualquer ciclo (passado, atual ou futuro), ancorado
-- na conciliacao mais recente de `saldos` -- complementa v_previsao (que so
-- olha para frente, dentro de horizonte_meses) permitindo a tela Resumo
-- mostrar, ao navegar para qualquer mes, "quanto eu teria acumulado ate
-- aqui" e nao so o saldo isolado daquele mes.
--
-- Formula: acumulado(ciclo) = valor_apurado + prefixo(ciclo) - prefixo(ancora),
-- onde prefixo(c) = soma de v_resumo_ciclo.saldo de todo ciclo <= c. Essa
-- unica soma-prefixo (sempre crescente, sem inverter sinal) funciona tanto
-- para ciclos depois da ancora (soma o que falta) quanto antes (subtrai o
-- que já tinha sido somado), sem precisar de dois ramos de calculo.
create view v_saldo_acumulado with (security_invoker = true) as
with ancora as (
  select distinct on (s.user_id) s.user_id, s.ciclo as ciclo_ancora, s.valor_apurado
  from saldos s
  order by s.user_id, s.ciclo desc
),
janela as (
  select a.user_id, a.ciclo_ancora, a.valor_apurado, c.horizonte_meses,
         coalesce(
           (select min(f.ciclo) from v_fluxo f where f.user_id = a.user_id),
           a.ciclo_ancora
         ) as inicio
  from ancora a
  join config c on c.user_id = a.user_id
),
ciclos as (
  select j.user_id, j.ciclo_ancora, j.valor_apurado,
         gs.ciclo::date as ciclo
  from janela j
  cross join lateral generate_series(
    least(j.ciclo_ancora, j.inicio),
    (ciclo(current_date) + j.horizonte_meses * interval '1 month')::date,
    interval '1 month'
  ) as gs(ciclo)
),
com_prefixo as (
  select c.user_id, c.ciclo_ancora, c.valor_apurado, c.ciclo,
         sum(coalesce(r.saldo, 0)) over (partition by c.user_id order by c.ciclo) as prefixo
  from ciclos c
  left join v_resumo_ciclo r on r.user_id = c.user_id and r.ciclo = c.ciclo
),
prefixo_ancora as (
  select user_id, prefixo as prefixo_no_ancora from com_prefixo where ciclo = ciclo_ancora
)
select
  cp.user_id,
  cp.ciclo,
  cp.valor_apurado + cp.prefixo - pa.prefixo_no_ancora as saldo_acumulado
from com_prefixo cp
join prefixo_ancora pa on pa.user_id = cp.user_id;

grant select on v_saldo_acumulado to authenticated;
