-- Portao 2 (ESPECIFICACAO.md secao 8): teste obrigatorio de vazamento de RLS.
-- 1) A role `anon`, sem sessao autenticada, nao pode enxergar NENHUMA linha
--    em NENHUMA tabela. Se qualquer linha voltar aqui, o RLS esta incorreto
--    e o projeto nao avanca.
-- 2) Um usuario autenticado so ve as proprias linhas, nunca as de outro.
begin;

-- No cloud, `supabase test db --linked` conecta com um usuario temporario
-- (cli_login_postgres) sem acesso ao schema `extensions`, onde mora o pgTAP:
-- o Postgres ignora o schema e responde "function plan does not exist".
-- Assumir `postgres` (o mesmo papel do teste local) resolve; vale so ate o
-- rollback do fim.
set role postgres;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(21);

-- Fixtures: dois usuarios, inseridos como postgres (superusuario bypassa RLS).
insert into auth.users (id, email) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'usuario1@local.test'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'usuario2@local.test');

insert into config (user_id) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');

insert into categorias (user_id, nome, tipo)
values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Mercado', 'despesa');

insert into avulsos (user_id, data, descricao, tipo, categoria_id, meio_pagamento, valor)
select 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_date, 'compra teste', 'despesa', id, 'pix', 100.00
from categorias where user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

-- Integracao bancaria (Fase C): uma linha de cada tabela nova para o usuario1.
insert into conexoes_pluggy (user_id, item_id, banco) values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'item-1', 'Banco');
insert into contas_pluggy (user_id, conta_pluggy_id, item_id, banco, tipo) values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'conta-1', 'item-1', 'Banco', 'BANK');
insert into transacoes_bancarias (user_id, pluggy_id, chave_dedupe, conta_pluggy_id, tipo_conta, data, valor, sentido, descricao)
values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'p1', 'k1', 'conta-1', 'BANK', current_date, 10, 'despesa', 'PIX TESTE');
insert into regras_categoria (user_id, padrao, categoria_id)
select 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'pix teste', id from categorias where user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

-- 1) anon, sem sessao: zero linhas em toda tabela.
set role anon;

select is((select count(*) from config)::int, 0, 'anon: config vazio');
select is((select count(*) from categorias)::int, 0, 'anon: categorias vazio');
select is((select count(*) from recorrentes)::int, 0, 'anon: recorrentes vazio');
select is((select count(*) from parcelamentos)::int, 0, 'anon: parcelamentos vazio');
select is((select count(*) from avulsos)::int, 0, 'anon: avulsos vazio');
select is((select count(*) from execucoes)::int, 0, 'anon: execucoes vazio');
select is((select count(*) from descontos_folha)::int, 0, 'anon: descontos_folha vazio');
select is((select count(*) from saldos)::int, 0, 'anon: saldos vazio');
select is((select count(*) from transacoes_bancarias)::int, 0, 'anon: transacoes_bancarias vazio');
select is((select count(*) from contas_pluggy)::int, 0, 'anon: contas_pluggy vazio');
select is((select count(*) from conexoes_pluggy)::int, 0, 'anon: conexoes_pluggy vazio');
select is((select count(*) from regras_categoria)::int, 0, 'anon: regras_categoria vazio');

set role postgres;

-- 2) usuario2 autenticado nao enxerga nada do usuario1.
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';

select is((select count(*) from categorias)::int, 0, 'usuario2 nao ve categorias do usuario1');
select is((select count(*) from avulsos)::int, 0, 'usuario2 nao ve avulsos do usuario1');
select is((select count(*) from transacoes_bancarias)::int, 0, 'usuario2 nao ve transacoes bancarias do usuario1');
select is((select count(*) from v_para_revisar)::int, 0, 'usuario2 nao ve a lista para revisar do usuario1');
select is((select count(*) from regras_categoria)::int, 0, 'usuario2 nao ve regras do usuario1');
select is((select count(*) from config)::int, 1, 'usuario2 ve apenas a propria linha de config, nunca a do usuario1');

set role postgres;

-- 3) usuario1 autenticado enxerga o que e dele.
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

select is((select count(*) from categorias)::int, 1, 'usuario1 ve a propria categoria');
select is((select count(*) from avulsos)::int, 1, 'usuario1 ve o proprio avulso');
select is((select count(*) from v_para_revisar)::int, 1, 'usuario1 ve a propria transacao para revisar');

set role postgres;

select * from finish();

rollback;
