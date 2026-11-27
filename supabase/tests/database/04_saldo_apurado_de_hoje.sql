-- Saldo apurado num dia qualquer (migration 20261126000001).
-- Cenario em 2030 (independe da data de hoje). Ciclo de marco/2030 vai de
-- 27/02/2030 (recebimento de fevereiro) ate o recebimento de marco. Saldo de
-- R$ 500 lido no banco em 02/03/2030:
--   credito  -300, compra 10/02 -> fatura vence 03/03 (depois de 02/03): pendente
--   pix      -100, em 28/02 (ja saiu da conta)                          : nao
--   pix       -50, em 02/03 (no proprio dia da leitura, ja saiu)        : nao
--   pix     +1000, em 10/03 (ainda vai entrar)                          : pendente
--   pendente = -300 + 1000 = 700 -> saldo no fim do ciclo = 1200
begin;

-- No cloud, `supabase test db --linked` conecta com um usuario temporario
-- (cli_login_postgres) sem acesso ao schema `extensions`, onde mora o pgTAP:
-- o Postgres ignora o schema e responde "function plan does not exist".
-- Assumir `postgres` (o mesmo papel do teste local) resolve; vale so ate o
-- rollback do fim.
set role postgres;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(11);

insert into auth.users (id, email)
values ('44444444-4444-4444-4444-444444444444', 'teste-apuracao@local.test');

insert into config (user_id) values ('44444444-4444-4444-4444-444444444444');

insert into categorias (user_id, nome, tipo) values
  ('44444444-4444-4444-4444-444444444444', 'Geral', 'despesa'),
  ('44444444-4444-4444-4444-444444444444', 'Salario', 'receita');

insert into avulsos (user_id, data, descricao, tipo, categoria_id, meio_pagamento, valor)
select '44444444-4444-4444-4444-444444444444', x.d::date, x.descr, x.tipo::tipo_lancamento, c.id,
       x.meio::meio_pagamento, x.v
from (values
  ('2030-02-10', 'Compra credito', 'despesa', 'credito',  300.00),
  ('2030-02-28', 'Pix antes',      'despesa', 'pix',      100.00),
  ('2030-03-02', 'Pix no dia',     'despesa', 'pix',       50.00),
  ('2030-03-10', 'Entrada depois', 'receita', 'pix',     1000.00)
) as x(d, descr, tipo, meio, v)
join categorias c
  on c.user_id = '44444444-4444-4444-4444-444444444444' and c.tipo = x.tipo::tipo_lancamento;

select is(
  (select count(*)::int from v_fluxo
   where user_id = '44444444-4444-4444-4444-444444444444' and ciclo = '2030-03-01'),
  4, 'os quatro lancamentos caem no ciclo de marco/2030');

select is(
  (select data_caixa from v_fluxo
   where user_id = '44444444-4444-4444-4444-444444444444' and descricao = 'Compra credito'),
  '2030-03-03'::date, 'data de caixa do credito e o vencimento da fatura, nao a data da compra');

insert into saldos (user_id, ciclo, valor_apurado, data_apuracao)
values ('44444444-4444-4444-4444-444444444444', '2030-03-01', 500.00, '2030-03-02');

select is(
  (select pendente from v_ancora_saldo where user_id = '44444444-4444-4444-4444-444444444444'),
  700.00::numeric, 'pendente: fatura ainda nao paga (-300) e entrada futura (+1000)');
select is(
  (select saldo_fim_ciclo from v_ancora_saldo where user_id = '44444444-4444-4444-4444-444444444444'),
  1200.00::numeric, 'saldo esperado no fim do ciclo = lido no banco + pendente');
select is(
  (select saldo_acumulado from v_saldo_acumulado
   where user_id = '44444444-4444-4444-4444-444444444444' and ciclo = '2030-03-01'),
  1200.00::numeric, 'acumulado do ciclo da ancora parte do saldo do fim do ciclo');
select is(
  (select saldo_acumulado from v_saldo_acumulado
   where user_id = '44444444-4444-4444-4444-444444444444' and ciclo = '2030-04-01'),
  1200.00::numeric, 'abril sem movimento mantem o saldo');

update saldos set data_apuracao = null
where user_id = '44444444-4444-4444-4444-444444444444';

select is(
  (select saldo_fim_ciclo from v_ancora_saldo where user_id = '44444444-4444-4444-4444-444444444444'),
  500.00::numeric, 'saldo antigo sem data mantem o significado de fim de ciclo (nada pendente)');

-- dia_no_ciclo: ciclo de setembro/2026 vai de 28/08 a 28/09.
select is(dia_no_ciclo('2026-09-01', 10), '2026-09-10'::date, 'dia 10 cai em setembro');
select is(dia_no_ciclo('2026-09-01', 28), '2026-08-28'::date, 'dia 28 ja ocorre no inicio do ciclo, em agosto');
select is(dia_no_ciclo('2026-09-01', 31), '2026-08-31'::date, 'dia 31 cai em 31/08, dentro do ciclo');
select is(dia_no_ciclo('2026-03-01', 30), '2026-02-28'::date, 'dia 30 em fevereiro e limitado ao fim do mes');

select * from finish();
rollback;
