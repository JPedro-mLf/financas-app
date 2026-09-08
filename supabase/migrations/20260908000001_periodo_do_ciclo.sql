-- Data de inicio e de fim de um ciclo, a partir do seu rotulo (o primeiro dia
-- do mes-rotulo, que e o que `ciclo()` devolve).
--
-- Pela definicao da secao 4, um ciclo comeca no dia em que o salario cai e vai
-- ate a vespera do proximo recebimento. Como `ciclo(d)` joga a data para o mes
-- seguinte quando `d >= data_recebimento(d)`, o ciclo rotulado C:
--   - comeca em data_recebimento(C - 1 mes)  -- o salario que o abriu
--   - termina em data_recebimento(C) - 1 dia -- vespera do proximo salario
--
-- Conferindo com o exemplo da propria secao 4: salario de 28/ago/2026 cai no
-- ciclo de setembro; logo ciclo_inicio('2026-09-01') = 2026-08-28, e
-- ciclo_fim('2026-09-01') = 2026-09-29 - 1 = 2026-09-28.
--
-- Isto e regra de calendario, entao vive no banco -- o front-end so exibe.

create or replace function ciclo_inicio(c date)
returns date language sql immutable as $$
  select data_recebimento((date_trunc('month', c) - interval '1 month')::date);
$$;

create or replace function ciclo_fim(c date)
returns date language sql immutable as $$
  select data_recebimento(c) - 1;
$$;

grant execute on function ciclo_inicio(date) to authenticated;
grant execute on function ciclo_fim(date) to authenticated;

-- O periodo tambem entra em v_resumo_ciclo: assim o Power BI (e qualquer
-- leitura da view) ja recebe o intervalo de cada ciclo pronto, sem precisar
-- recalcular nada do lado de fora.
create or replace view v_resumo_ciclo with (security_invoker = true) as
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
  coalesce(sum(valor) filter (where tipo = 'despesa' and status in ('previsto', 'pendente')), 0) as despesas_previstas,
  ciclo_inicio(ciclo) as periodo_inicio,
  ciclo_fim(ciclo) as periodo_fim
from v_fluxo
where status is distinct from 'cancelado'
group by user_id, ciclo;
