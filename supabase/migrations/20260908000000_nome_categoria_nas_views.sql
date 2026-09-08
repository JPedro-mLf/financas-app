-- Acrescenta `categoria_nome` as views derivadas. Ate aqui elas expunham so
-- `categoria_id` (uuid), o que deixa qualquer leitura crua -- Table Editor do
-- Supabase, Power BI, consulta SQL avulsa -- ilegivel.
--
-- O nome entra APENAS nas views. As tabelas base seguem normalizadas, sem
-- coluna de nome duplicada: e a mesma regra que a secao 6 da especificacao ja
-- aplicou ao remover as colunas calculadas da planilha antiga -- dado
-- derivado que se duplica em coluna vira dado desatualizado no dia em que a
-- categoria for renomeada.
--
-- Como as colunas novas vao no FIM da lista de cada view, `create or replace`
-- funciona sem precisar dropar (Postgres so exige que as colunas existentes
-- fiquem iguais e na mesma ordem).

create or replace view v_parcelas with (security_invoker = true) as
select p.id as origem_id, 'parcelamento' as origem, p.user_id,
       p.descricao, p.categoria_id, p.meio_pagamento,
       n as numero_parcela, p.num_parcelas,
       p.valor_parcela as valor,
       (ciclo_caixa(p.data_compra, p.meio_pagamento)
         + (n - 1) * interval '1 month')::date as ciclo,
       cat.nome as categoria_nome
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
  cat.nome as categoria_nome
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

create or replace view v_avulsos with (security_invoker = true) as
select
  a.id as origem_id, 'avulso' as origem, a.user_id,
  a.descricao, a.tipo, a.categoria_id, a.meio_pagamento,
  ciclo_caixa(a.data, a.meio_pagamento) as ciclo,
  a.valor,
  'pago'::status_execucao as status,
  a.data as data_efetiva,
  cat.nome as categoria_nome
from avulsos a
join categorias cat on cat.id = a.categoria_id;

create or replace view v_fluxo with (security_invoker = true) as
select origem_id, origem, user_id,
       descricao || ' (' || numero_parcela || '/' || num_parcelas || ')' as descricao,
       'despesa'::tipo_lancamento as tipo,
       categoria_id, meio_pagamento, ciclo, valor,
       'pago'::status_execucao as status,
       null::date as data_efetiva,
       categoria_nome
from v_parcelas
union all
select origem_id, origem, user_id, descricao, tipo, categoria_id, meio_pagamento,
       ciclo, valor, status, data_efetiva, categoria_nome
from v_recorrentes_ciclo
union all
select origem_id, origem, user_id, descricao, tipo, categoria_id, meio_pagamento,
       ciclo, valor, status, data_efetiva, categoria_nome
from v_avulsos;

create or replace view v_reserva_estimados with (security_invoker = true) as
select
  r.id as recorrente_id,
  r.user_id,
  r.descricao,
  r.categoria_id,
  sum(r.valor_previsto - coalesce(e.valor_realizado, r.valor_previsto)) as reserva_acumulada,
  cat.nome as categoria_nome
from recorrentes r
join execucoes e
  on e.user_id = r.user_id
 and e.recorrente_id = r.id
 and e.status = 'pago'
join categorias cat on cat.id = r.categoria_id
where r.estimado
group by r.id, r.user_id, r.descricao, r.categoria_id, cat.nome;
