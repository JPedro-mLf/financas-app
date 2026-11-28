-- Descontos em folha e salario casado pelo liquido (migration 20261128000008).
-- Valores do usuario real: bruto 3.765,60; INSS 9,042%; seguro 6,78; plano
-- dentario 14,87; almoco descontado na folha 21,00 (recorrente de folha).
--   INSS sobre o previsto = round(3765.60 * 9.042%) = 340,49
--   liquido esperado      = 3765,60 - 340,49 - 6,78 - 14,87 - 21,00 = 3.382,46
begin;

-- Mesmo preambulo dos demais testes (ver 01_calendario.sql).
set role postgres;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(8);

insert into auth.users (id, email) values ('88888888-8888-8888-8888-888888888888', 'teste-salario@local.test');
insert into config (user_id) values ('88888888-8888-8888-8888-888888888888');
insert into categorias (id, user_id, nome, tipo) values
  ('f0000000-0000-0000-0000-000000000001', '88888888-8888-8888-8888-888888888888', 'Salario', 'receita'),
  ('f0000000-0000-0000-0000-000000000002', '88888888-8888-8888-8888-888888888888', 'Alimentacao', 'despesa');
insert into recorrentes (id, user_id, descricao, tipo, categoria_id, meio_pagamento, valor_previsto, dia_referencia, data_inicio) values
  ('f1000000-0000-0000-0000-000000000001', '88888888-8888-8888-8888-888888888888', 'Folha de salario', 'receita',
   'f0000000-0000-0000-0000-000000000001', 'folha', 3765.60, 29, current_date - 120),
  ('f1000000-0000-0000-0000-000000000002', '88888888-8888-8888-8888-888888888888', 'Almoco na fabrica', 'despesa',
   'f0000000-0000-0000-0000-000000000002', 'folha', 21.00, 29, current_date - 120);
insert into descontos_folha (user_id, descricao, percentual, valor_fixo) values
  ('88888888-8888-8888-8888-888888888888', 'INSS', 9.042, null),
  ('88888888-8888-8888-8888-888888888888', 'Seguro de vida', null, 6.78),
  ('88888888-8888-8888-8888-888888888888', 'Plano dentario', null, 14.87);

-- Ciclo que o deposito de hoje financia (data + 5 dias).
create temp table c as select ciclo((current_date + 5)::date) as ciclo;

select is((select count(*)::int from v_descontos_ciclo
           where user_id = '88888888-8888-8888-8888-888888888888' and ciclo = (select ciclo from c)),
  3, 'cada desconto vira uma linha de despesa no ciclo do salario');
select is((select valor from v_descontos_ciclo
           where user_id = '88888888-8888-8888-8888-888888888888' and ciclo = (select ciclo from c) and descricao = 'INSS'),
  340.49::numeric, 'INSS = 9,042% do bruto previsto, arredondado');
select is(liquido_esperado('88888888-8888-8888-8888-888888888888', 3765.60, (select ciclo from c)),
  3382.46::numeric, 'liquido esperado = bruto - descontos - recorrentes de folha');

-- Deposito real do salario (liquido), 0,8% acima do esperado.
insert into transacoes_bancarias (id, user_id, pluggy_id, chave_dedupe, conta_pluggy_id, tipo_conta, data, valor, sentido, descricao, tipo_operacao, meio_inferido)
values ('f2000000-0000-0000-0000-000000000001', '88888888-8888-8888-8888-888888888888', 'p-s1', 'k-s1', 'conta', 'BANK',
        current_date, 3411.01, 'receita', 'SALARIO EMPRESA', 'FOLHA_PAGAMENTO', 'folha');
select casar_transacoes_bancarias('88888888-8888-8888-8888-888888888888');

select is((select estado || '/' || vinculo_tipo from transacoes_bancarias where id = 'f2000000-0000-0000-0000-000000000001'),
  'vinculada/execucao', 'deposito de folha casa com o salario pelo liquido esperado');
select is((select sum(case when tipo = 'receita' then valor else -valor end) from v_fluxo
           where user_id = '88888888-8888-8888-8888-888888888888' and ciclo = (select ciclo from c)
             and meio_pagamento = 'folha'),
  3411.01::numeric, 'bruto realizado - descontos - almoco = liquido do banco, ao centavo');
select ok((select valor from v_fluxo
           where user_id = '88888888-8888-8888-8888-888888888888' and ciclo = (select ciclo from c)
             and origem = 'recorrente' and descricao = 'Folha de salario') > 3765.60,
  'a diferenca (hora extra/reajuste) foi para o bruto do mes');
select is((select status::text from v_descontos_ciclo
           where user_id = '88888888-8888-8888-8888-888888888888' and ciclo = (select ciclo from c) and descricao = 'INSS'),
  'pago', 'descontos acompanham o status do salario');

-- Hora extra grande no mes seguinte (+27%): nao casa sozinho, vira sugestao.
insert into transacoes_bancarias (id, user_id, pluggy_id, chave_dedupe, conta_pluggy_id, tipo_conta, data, valor, sentido, descricao, tipo_operacao, meio_inferido)
values ('f2000000-0000-0000-0000-000000000002', '88888888-8888-8888-8888-888888888888', 'p-s2', 'k-s2', 'conta', 'BANK',
        current_date + 31, 4300.00, 'receita', 'SALARIO EMPRESA', 'FOLHA_PAGAMENTO', 'folha');
select casar_transacoes_bancarias('88888888-8888-8888-8888-888888888888');
select is((select estado || '/' || jsonb_array_length(candidatos) from transacoes_bancarias
           where id = 'f2000000-0000-0000-0000-000000000002'),
  'para_revisar/1', 'salario 27% acima do esperado vira sugestao (vincular com um toque)');

select * from finish();
rollback;
