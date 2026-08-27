-- Corrige v_recorrentes_ciclo: gerar uma data de calendario por mes
-- (dia_referencia clampado) e so depois mapear cada uma para um ciclo
-- fazia um recorrente perto do dia de recebimento (ex.: dia_referencia=29,
-- meio='folha') duplicar num ciclo e sumir no ciclo seguinte -- porque
-- data_recebimento() se desloca +-2 dias por causa do ajuste de fim de
-- semana, e "dia 29 fixo" as vezes cai antes desse limiar, as vezes depois,
-- para o MESMO dia do calendario em meses diferentes.
--
-- Corrigido gerando a SEQUENCIA DE CICLOS diretamente (sempre consecutiva,
-- sem essa ambiguidade) em vez de gerar datas de calendario e recalcular o
-- ciclo de cada uma. dia_referencia passa a ser so metadado informativo,
-- nao entra mais no calculo de qual ciclo cada ocorrencia pertence.
create or replace view v_recorrentes_ciclo with (security_invoker = true) as
select
  r.id as origem_id, 'recorrente' as origem, r.user_id,
  r.descricao, r.tipo, r.categoria_id, r.meio_pagamento, r.estimado,
  gs.ciclo::date as ciclo,
  coalesce(e.valor_realizado, r.valor_previsto) as valor,
  coalesce(e.status, 'previsto'::status_execucao) as status,
  e.data_efetiva
from recorrentes r
join config c on c.user_id = r.user_id
cross join lateral generate_series(
  ciclo_caixa(r.data_inicio, r.meio_pagamento),
  (ciclo(current_date) + c.horizonte_meses * interval '1 month')::date,
  interval '1 month'
) as gs(ciclo)
left join execucoes e
  on e.user_id = r.user_id
 and e.recorrente_id = r.id
 and e.ciclo = gs.ciclo::date
where r.ativo
  and (r.data_fim is null or gs.ciclo::date <= ciclo_caixa(r.data_fim, r.meio_pagamento));
