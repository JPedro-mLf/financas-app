-- Fase C da integracao Open Finance (ESPECIFICACAO.md 14.5/14.7): contagem.
--
-- Invariante da contagem unica: cada transacao do banco entra no saldo e na
-- previsao NO MAXIMO uma vez, por exatamente um caminho --
--   provisoria (aqui, v_banco_provisorio), OU
--   pelo cadastro a que foi vinculada (execucao, parcela, avulso), OU
--   pelo avulso criado na confirmacao.
-- Coberta pelo teste 06_contagem_unica (Portao 3).

-- Quem pode contar antes de revisado (14.5): so compra no cartao de credito e
-- compra no debito. Pix, transferencia, boleto, tarifa, estorno etc. so contam
-- depois de confirmados.
create or replace function elegivel_provisorio(tipo_conta text, sentido tipo_lancamento, tipo_operacao text)
returns boolean language sql immutable as $$
  select sentido = 'despesa' and (
    (tipo_conta = 'CREDIT' and coalesce(tipo_operacao, '') not in ('PAGAMENTO_FATURA', 'TARIFA', 'ESTORNO', 'CASHBACK'))
    or (tipo_conta = 'BANK' and tipo_operacao = 'CARTAO')
  );
$$;

-- Provisorias: elegiveis, ainda para revisar, SEM candidato de casamento (com
-- candidato, quem ja conta e o cadastro -- 14.16) e que nao sejam
-- transferencia para si mesmo. Mesmo formato dos ramos de v_fluxo.
create or replace view v_banco_provisorio with (security_invoker = true) as
select t.id as origem_id,
       'banco'::text as origem,
       t.user_id,
       t.descricao,
       t.sentido as tipo,
       t.categoria_sugerida_id as categoria_id,
       coalesce(t.meio_inferido,
                case when t.tipo_conta = 'CREDIT' then 'credito' else 'debito' end::meio_pagamento) as meio_pagamento,
       ciclo_caixa(t.data,
                   coalesce(t.meio_inferido,
                            case when t.tipo_conta = 'CREDIT' then 'credito' else 'debito' end::meio_pagamento),
                   t.user_id) as ciclo,
       t.valor,
       'pago'::status_execucao as status,
       t.data as data_efetiva,
       cat.nome as categoria_nome,
       t.data_compra_original as data_compra,
       null::smallint as dia_referencia
from transacoes_bancarias t
left join categorias cat on cat.id = t.categoria_sugerida_id
where t.estado = 'para_revisar'
  and t.candidatos = '[]'::jsonb
  and not t.transferencia_propria
  and elegivel_provisorio(t.tipo_conta, t.sentido, t.tipo_operacao);

-- v_fluxo ganha o ramo do banco e a coluna `provisorio` (no fim: create or
-- replace so permite acrescentar). Segue sendo a unica tabela-fato do Power BI.
create or replace view v_fluxo with (security_invoker = true) as
select f.origem_id, f.origem, f.user_id, f.descricao, f.tipo, f.categoria_id,
       f.meio_pagamento, f.ciclo, f.valor, f.status, f.data_efetiva,
       f.categoria_nome, f.data_compra, f.dia_referencia,
       case when f.meio_pagamento = 'credito'
            then fatura_vencimento_no_ciclo(f.ciclo, f.user_id)
       end as fatura_vencimento,
       case
         when f.meio_pagamento = 'credito' then fatura_vencimento_no_ciclo(f.ciclo, f.user_id)
         when f.data_efetiva is not null then f.data_efetiva
         when f.meio_pagamento = 'folha' then ciclo_inicio(f.ciclo)
         when f.origem = 'parcelamento' then dia_no_ciclo(f.ciclo, extract(day from f.data_compra)::int)
         when f.dia_referencia is not null then dia_no_ciclo(f.ciclo, f.dia_referencia)
       end as data_caixa,
       f.provisorio
from (
  select origem_id, origem, user_id,
         descricao || ' (' || numero_parcela || '/' || num_parcelas || ')' as descricao,
         'despesa'::tipo_lancamento as tipo,
         categoria_id, meio_pagamento, ciclo, valor,
         'pago'::status_execucao as status,
         null::date as data_efetiva,
         categoria_nome,
         data_compra,
         null::smallint as dia_referencia,
         false as provisorio
  from v_parcelas
  union all
  select origem_id, origem, user_id, descricao, tipo, categoria_id, meio_pagamento,
         ciclo, valor, status, data_efetiva, categoria_nome,
         null::date as data_compra,
         dia_referencia,
         false
  from v_recorrentes_ciclo
  union all
  select origem_id, origem, user_id, descricao, tipo, categoria_id, meio_pagamento,
         ciclo, valor, status, data_efetiva, categoria_nome,
         null::date as data_compra,
         null::smallint as dia_referencia,
         false
  from v_avulsos
  union all
  select origem_id, origem, user_id, descricao, tipo, categoria_id, meio_pagamento,
         ciclo, valor, status, data_efetiva, categoria_nome, data_compra, dia_referencia,
         true
  from v_banco_provisorio
) f;

-- Lista da aba "Para revisar": so o que precisa de decisao, ja com sugestoes e
-- dizendo se a linha ja conta no saldo (provisoria) ou nao.
create or replace view v_para_revisar with (security_invoker = true) as
select t.id, t.user_id, t.data, t.valor, t.sentido, t.descricao,
       t.tipo_conta, t.tipo_operacao, t.meio_inferido,
       t.parcela_numero, t.parcela_total, t.data_compra_original,
       t.transferencia_propria, t.candidatos,
       t.categoria_sugerida_id, cat.nome as categoria_sugerida_nome,
       c.banco,
       ciclo_caixa(t.data,
                   coalesce(t.meio_inferido,
                            case when t.tipo_conta = 'CREDIT' then 'credito' else 'debito' end::meio_pagamento),
                   t.user_id) as ciclo,
       (t.candidatos = '[]'::jsonb and not t.transferencia_propria
        and elegivel_provisorio(t.tipo_conta, t.sentido, t.tipo_operacao)) as conta_no_saldo
from transacoes_bancarias t
left join categorias cat on cat.id = t.categoria_sugerida_id
left join contas_pluggy c on c.user_id = t.user_id and c.conta_pluggy_id = t.conta_pluggy_id
where t.estado = 'para_revisar';

-- Contadores do Resumo (14.11): quantos itens esperam revisao, quanto ja esta
-- no saldo como provisorio e quanto esta fora (Pix, entradas...) ate confirmar.
-- Valores com sinal: receita +, despesa -.
create or replace view v_resumo_banco with (security_invoker = true) as
select user_id,
       count(*) as itens_para_revisar,
       coalesce(sum(case when sentido = 'receita' then valor else -valor end)
                filter (where conta_no_saldo), 0) as valor_provisorio_no_saldo,
       coalesce(sum(case when sentido = 'receita' then valor else -valor end)
                filter (where not conta_no_saldo), 0) as valor_fora_do_saldo
from v_para_revisar
group by user_id;

-- Saude das conexoes (14.9): consentimento revogado/vencido devolve listas
-- vazias SEM erro, entao o atraso tem de ser detectado por data.
create or replace view v_saude_conexoes with (security_invoker = true) as
select user_id, item_id, banco, status, ultima_atualizacao, ultima_transacao_em,
       consentimento_expira_em,
       (ultima_atualizacao is null
        or ultima_atualizacao < now() - interval '48 hours'
        or coalesce(status, '') <> 'UPDATED'
        or (consentimento_expira_em is not null and consentimento_expira_em < now())) as atrasada,
       (consentimento_expira_em is not null
        and consentimento_expira_em < now() + interval '30 days') as expira_em_breve
from conexoes_pluggy;

-- GRANTs: authenticated le; anon nada (os padroes antigos da producao dariam
-- SELECT a anon em views novas -- ver 20261128000000).
revoke all on v_banco_provisorio, v_para_revisar, v_resumo_banco, v_saude_conexoes from anon;
grant select on v_banco_provisorio, v_para_revisar, v_resumo_banco, v_saude_conexoes to authenticated;
grant execute on function elegivel_provisorio(text, tipo_lancamento, text) to authenticated;
