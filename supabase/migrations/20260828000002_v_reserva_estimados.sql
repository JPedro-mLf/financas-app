-- Reserva acumulada dos itens "estimado" (custo virtual, ex.: combustivel,
-- manutencao do carro -- secao 6 da especificacao). Quando o valor
-- realizado de um ciclo confirmado ('pago') fica abaixo do previsto, a
-- diferenca "sobra" e entra na reserva; quando fica acima, a reserva e
-- consumida. Ciclos ainda sem execucao confirmada nao contam (diferenca
-- zero), entao a reserva so reflete o que o usuario efetivamente registrou.
create view v_reserva_estimados with (security_invoker = true) as
select
  r.id as recorrente_id,
  r.user_id,
  r.descricao,
  r.categoria_id,
  sum(r.valor_previsto - coalesce(e.valor_realizado, r.valor_previsto)) as reserva_acumulada
from recorrentes r
join execucoes e
  on e.user_id = r.user_id
 and e.recorrente_id = r.id
 and e.status = 'pago'
where r.estimado
group by r.id, r.user_id, r.descricao, r.categoria_id;

grant select on v_reserva_estimados to authenticated;
