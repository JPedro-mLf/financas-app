-- Leva ate v_fluxo as datas que cada origem realmente tem guardadas, para o
-- Extrato poder exibir "quando" cada linha aconteceu (validacao visual de que
-- o lancamento caiu no ciclo certo).
--
-- Cada origem tem uma nocao diferente de data, e nenhuma delas serve para as
-- outras -- por isso sao colunas separadas e nomeadas pelo que sao, em vez de
-- uma coluna generica que significaria uma coisa em cada linha:
--
--   avulso      -> data_efetiva (ja existia): a data real do lancamento
--   recorrente  -> data_efetiva quando ha execucao confirmada; fora isso, so
--                  o dia_referencia ("todo dia 15"), que e o que o cadastro
--                  sabe. Nao existe data real de um mes que ainda nao ocorreu.
--   parcela     -> nao tem data propria nenhuma. O que existe e a data_compra
--                  da serie inteira, util para saber de onde a parcela veio.
--
-- Nada aqui e derivado/calculado: sao colunas ja armazenadas, so trazidas
-- para a superficie.

create or replace view v_parcelas with (security_invoker = true) as
select p.id as origem_id, 'parcelamento' as origem, p.user_id,
       p.descricao, p.categoria_id, p.meio_pagamento,
       n as numero_parcela, p.num_parcelas,
       p.valor_parcela as valor,
       (ciclo_caixa(p.data_compra, p.meio_pagamento)
         + (n - 1) * interval '1 month')::date as ciclo,
       cat.nome as categoria_nome,
       p.data_compra
from parcelamentos p
join categorias cat on cat.id = p.categoria_id
cross join lateral generate_series(1, p.num_parcelas) as n;

create or replace view v_recorrentes_ciclo with (security_invoker = true) as
select
  r.id as origem_id, 'recorrente' as origem, r.user_id,
  r.descricao, r.tipo, r.categoria_id, r.meio_pagamento, r.estimado,
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

create or replace view v_fluxo with (security_invoker = true) as
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
from v_avulsos;
