-- Juros de cheque especial na projecao (migration 20261126000000).
-- Cenario calculado a mao, com ancora em 2030 para nao depender da data de
-- hoje (o corte de juros e max(ancora, ciclo atual) = a propria ancora).
-- Taxa de 10% para a conta fechar de cabeca:
--   jan/2030 ancora   -1000,00                     (sem juros: e o corte)
--   fev/2030 +500     juros 100,00 -> -1000 + 500 - 100 = -600,00
--   mar/2030 sem mov. juros  60,00 ->  -600       -  60 = -660,00
--   abr/2030 +1000    juros  66,00 ->  -660 +1000 -  66 =  274,00
begin;

select plan(9);

insert into auth.users (id, email)
values ('33333333-3333-3333-3333-333333333333', 'teste-cheque@local.test');

insert into config (user_id) values ('33333333-3333-3333-3333-333333333333');

select is(
  (select taxa_cheque_especial from config where user_id = '33333333-3333-3333-3333-333333333333'),
  0.08965::numeric,
  'taxa padrao do cheque especial e 8,965% a.m.'
);

update config set taxa_cheque_especial = 0.10, horizonte_meses = 3
where user_id = '33333333-3333-3333-3333-333333333333';

insert into categorias (user_id, nome, tipo)
values ('33333333-3333-3333-3333-333333333333', 'Salario', 'receita');

insert into avulsos (user_id, data, descricao, tipo, categoria_id, meio_pagamento, valor)
select '33333333-3333-3333-3333-333333333333', d::date, 'Entrada teste', 'receita', c.id, 'pix', v
from categorias c,
     (values ('2030-02-10', 500.00), ('2030-04-10', 1000.00)) as x(d, v)
where c.user_id = '33333333-3333-3333-3333-333333333333';

insert into saldos (user_id, ciclo, valor_apurado)
values ('33333333-3333-3333-3333-333333333333', '2030-01-01', -1000.00);

create temp view t as
select ciclo, saldo_acumulado, juros_cheque_especial
from v_saldo_acumulado
where user_id = '33333333-3333-3333-3333-333333333333';

select is((select juros_cheque_especial from t where ciclo = '2030-01-01'), 0::numeric,
  'ciclo da ancora nao cobra juros (ja e realizado)');
select is((select saldo_acumulado from t where ciclo = '2030-01-01'), -1000.00::numeric,
  'ancora mantem o valor apurado');
select is((select juros_cheque_especial from t where ciclo = '2030-02-01'), 100.00::numeric,
  'fev: 10% sobre os 1000 negativos do fim de jan');
select is((select saldo_acumulado from t where ciclo = '2030-02-01'), -600.00::numeric,
  'fev: -1000 + 500 - 100 de juros');
select is((select saldo_acumulado from t where ciclo = '2030-03-01'), -660.00::numeric,
  'mar: juros compostos sobre o negativo de fev, mesmo sem movimento');
select is((select juros_cheque_especial from t where ciclo = '2030-04-01'), 66.00::numeric,
  'abr: juros sobre -660 ainda sao cobrados no mes em que o saldo volta a ficar positivo');
select is((select saldo_acumulado from t where ciclo = '2030-04-01'), 274.00::numeric,
  'abr: -660 + 1000 - 66');

select results_eq(
  $$ select ciclo, saldo_projetado, juros_cheque_especial from v_previsao
     where user_id = '33333333-3333-3333-3333-333333333333' order by ciclo $$,
  $$ select ciclo, saldo_acumulado, juros_cheque_especial from t
     where ciclo > '2030-01-01' order by ciclo $$,
  'v_previsao usa a mesma projecao com juros de v_saldo_acumulado'
);

select * from finish();
rollback;
