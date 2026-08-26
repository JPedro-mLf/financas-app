-- Portao 2 (ESPECIFICACAO.md secao 8): teste obrigatorio de vazamento de RLS.
-- 1) A role `anon`, sem sessao autenticada, nao pode enxergar NENHUMA linha
--    em NENHUMA tabela. Se qualquer linha voltar aqui, o RLS esta incorreto
--    e o projeto nao avanca.
-- 2) Um usuario autenticado so ve as proprias linhas, nunca as de outro.
begin;

select plan(13);

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

reset role;

-- 2) usuario2 autenticado nao enxerga nada do usuario1.
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';

select is((select count(*) from categorias)::int, 0, 'usuario2 nao ve categorias do usuario1');
select is((select count(*) from avulsos)::int, 0, 'usuario2 nao ve avulsos do usuario1');
select is((select count(*) from config)::int, 1, 'usuario2 ve apenas a propria linha de config, nunca a do usuario1');

reset role;

-- 3) usuario1 autenticado enxerga o que e dele.
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

select is((select count(*) from categorias)::int, 1, 'usuario1 ve a propria categoria');
select is((select count(*) from avulsos)::int, 1, 'usuario1 ve o proprio avulso');

reset role;

select * from finish();

rollback;
