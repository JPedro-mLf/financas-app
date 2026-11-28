-- Visao secundaria "Revisadas" da tela de revisao (ESPECIFICACAO.md 14.5/14.11):
-- confirmadas, ignoradas e vinculadas (inclusive as que o motor casou sozinho,
-- para o usuario conferir), com o ciclo ja calculado no banco e o que foi
-- vinculado, para o botao Desfazer.
create or replace view v_revisadas with (security_invoker = true) as
select t.id, t.user_id, t.data, t.valor, t.sentido, t.descricao,
       t.estado, t.vinculo_tipo, t.vinculo_automatico, t.removida_em,
       c.banco,
       ciclo_caixa(t.data,
                   coalesce(t.meio_inferido,
                            case when t.tipo_conta = 'CREDIT' then 'credito' else 'debito' end::meio_pagamento),
                   t.user_id) as ciclo,
       coalesce(a.descricao, p.descricao, r.descricao) as vinculado_a,
       t.atualizada_em
from transacoes_bancarias t
left join contas_pluggy c on c.user_id = t.user_id and c.conta_pluggy_id = t.conta_pluggy_id
left join avulsos a on t.vinculo_tipo = 'avulso' and a.id = t.vinculo_id
left join parcelamentos p on t.vinculo_tipo = 'parcelamento' and p.id = t.vinculo_id
left join execucoes e on t.vinculo_tipo = 'execucao' and e.id = t.vinculo_id
left join recorrentes r on r.id = e.recorrente_id
where t.estado in ('confirmada', 'ignorada', 'vinculada');

revoke all on v_revisadas from anon;
grant select on v_revisadas to authenticated;
