-- Saldo apurado passa a ser o saldo da conta NUM DIA QUALQUER (ESPECIFICACAO.md
-- secao 7). Antes, `valor_apurado` era tratado como o saldo do FIM do ciclo da
-- ancora (os lancamentos daquele ciclo nao eram somados) -- certo so se o
-- usuario registrasse no dia exato. Agora a ancora guarda a data da apuracao e
-- o motor soma apenas o que, naquela data, ainda nao passou pela conta:
--
--   saldo no fim do ciclo da ancora = valor_apurado + pendente
--
-- "Passou pela conta" depende de quando o dinheiro de fato se move (data de
-- caixa, nova coluna de v_fluxo):
--   credito                         -> vencimento da fatura do ciclo
--   avulso fora do credito          -> data do lancamento
--   parcela fora do credito         -> mesmo dia do mes da compra, no ciclo
--   folha (salario)                 -> inicio do ciclo (dia do recebimento)
--   recorrente fora do credito      -> data em que foi pago; sem confirmacao,
--                                      o dia previsto (dia_referencia). Se ja
--                                      passou, o saldo do banco ja o reflete.
--
-- Saldos registrados antes desta migration ficam com data_apuracao nula e
-- mantem o significado antigo (fim do ciclo, nada pendente): nenhum numero
-- muda ate o usuario registrar um saldo novo.

alter table saldos add column data_apuracao date;

comment on column saldos.data_apuracao is
  'Dia em que valor_apurado foi lido no banco. Nula = saldo do fim do ciclo (registros anteriores a nov/2026).';

-- Dia `dia` do mes posicionado dentro do intervalo do ciclo c
-- [ciclo_inicio(c), ciclo_fim(c)], limitado ao fim do mes e ao fim do ciclo.
create or replace function dia_no_ciclo(c date, dia int)
returns date language sql immutable as $$
  with l as (
    select ciclo_inicio(c) as ini, ciclo_fim(c) as fim
  ),
  candidatos as (
    select l.ini, l.fim,
           (date_trunc('month', l.ini)::date
             + (least(dia, extract(day from (date_trunc('month', l.ini) + interval '1 month - 1 day'))::int) - 1)
           ) as no_mes_inicio,
           (date_trunc('month', c)::date
             + (least(dia, extract(day from (date_trunc('month', c) + interval '1 month - 1 day'))::int) - 1)
           ) as no_mes_ciclo
    from l
  )
  select case when no_mes_inicio >= ini then no_mes_inicio
              else least(no_mes_ciclo, fim) end
  from candidatos;
$$;

grant execute on function dia_no_ciclo(date, int) to authenticated;

-- v_fluxo ganha data_caixa no fim (create or replace so permite acrescentar).
create or replace view v_fluxo with (security_invoker = true) as
select f.*,
       case when f.meio_pagamento = 'credito'
            then fatura_vencimento_no_ciclo(f.ciclo)
       end as fatura_vencimento,
       case
         when f.meio_pagamento = 'credito' then fatura_vencimento_no_ciclo(f.ciclo)
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

-- Ancora da projecao: o saldo registrado mais recente e o que ainda falta
-- passar pela conta no ciclo dele. Unico lugar com essa regra; a tela
-- Configuracao le daqui para mostrar o saldo esperado no fim do ciclo.
create or replace view v_ancora_saldo with (security_invoker = true) as
with ancora as (
  select distinct on (s.user_id) s.user_id, s.ciclo, s.valor_apurado, s.data_apuracao
  from saldos s
  order by s.user_id, s.ciclo desc
)
select a.user_id, a.ciclo, a.data_apuracao, a.valor_apurado,
       coalesce(p.pendente, 0) as pendente,
       a.valor_apurado + coalesce(p.pendente, 0) as saldo_fim_ciclo
from ancora a
left join lateral (
  select sum(case when f.tipo = 'receita' then f.valor else -f.valor end) as pendente
  from v_fluxo f
  where f.user_id = a.user_id
    and f.ciclo = a.ciclo
    and a.data_apuracao is not null
    and f.status is distinct from 'cancelado'
    and f.data_caixa > a.data_apuracao
) p on true;

grant select on v_ancora_saldo to authenticated;

-- Mesma view da migration 20261126000000; so a ancora muda: parte do saldo no
-- fim do ciclo da ancora (valor_apurado + pendente), nao do valor cru.
create or replace view v_saldo_acumulado with (security_invoker = true) as
with recursive ancora as (
  select user_id, ciclo as ciclo_ancora, saldo_fim_ciclo as valor_apurado
  from v_ancora_saldo
),
janela as (
  select a.user_id, a.ciclo_ancora, a.valor_apurado, c.horizonte_meses,
         c.taxa_cheque_especial as taxa,
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
