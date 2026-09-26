-- Vencimento da fatura em que cada lancamento no credito caiu, para o Extrato
-- deixar explicito POR QUE uma compra aparece num ciclo que nao contem a data
-- da compra (ex.: compra de 29/07 no ciclo de setembro, porque a fatura vence
-- 03/09). A regra de competencia (secao 4) nao muda -- isto so a torna visivel.
--
-- Nao e preciso recalcular a partir da data de cada compra: todo lancamento no
-- credito que cai no ciclo C tem a fatura vencendo no dia_vencimento do mes C.
-- Motivo: ciclo_caixa no credito e ciclo(fatura_vence(d)), e fatura_vence
-- sempre cai no dia_vencimento (03) de algum mes M; como 03 e antes do dia de
-- recebimento de M (~27-30), ciclo() devolve o proprio M. Isso depende da
-- mesma premissa ja registrada na secao 5 (dia_vencimento < dia_fechamento).
-- Tambem vale para recorrentes ainda nao pagos, que nao tem data propria.

create or replace function fatura_vencimento_no_ciclo(c date)
returns date language sql stable as $$
  select date_trunc('month', c)::date + (cfg.dia_vencimento - 1)
  from config cfg;
$$;

grant execute on function fatura_vencimento_no_ciclo(date) to authenticated;

create or replace view v_fluxo with (security_invoker = true) as
select f.*,
       case when f.meio_pagamento = 'credito'
            then fatura_vencimento_no_ciclo(f.ciclo)
       end as fatura_vencimento
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
