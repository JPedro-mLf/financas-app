-- Portao 4 (ESPECIFICACAO.md 14.12): privilegios minimos por role, em toda
-- tabela e view do schema public (migration 20261128000000). Varre o catalogo,
-- entao cobre tambem objetos criados por migrations futuras: se alguma reabrir
-- uma permissao, este teste falha e lista o objeto.
begin;

-- Mesmo preambulo dos demais testes (ver 01_calendario.sql).
set role postgres;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(7);

create temp view objetos as
select c.oid, c.relname, c.relkind
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind in ('r', 'v');

select is(
  (select string_agg(relname, ', ') from objetos
   where has_table_privilege('anon', oid, 'INSERT') or has_table_privilege('anon', oid, 'UPDATE')
      or has_table_privilege('anon', oid, 'DELETE') or has_table_privilege('anon', oid, 'TRUNCATE')),
  null, 'anon nao escreve em nenhuma tabela ou view');

select is(
  (select string_agg(relname, ', ') from objetos
   where relkind = 'v' and has_table_privilege('anon', oid, 'SELECT')),
  null, 'anon nao le nenhuma view');

select is(
  (select string_agg(relname, ', ') from objetos
   where has_table_privilege('authenticated', oid, 'TRUNCATE')
      or has_table_privilege('anon', oid, 'TRUNCATE')),
  null, 'ninguem da API pode TRUNCATE (o TRUNCATE nao passa pelo RLS)');

select is(
  (select string_agg(relname, ', ') from objetos
   where relkind = 'v' and (has_table_privilege('authenticated', oid, 'INSERT')
      or has_table_privilege('authenticated', oid, 'UPDATE')
      or has_table_privilege('authenticated', oid, 'DELETE'))),
  null, 'authenticated so le as views');

-- O que o app precisa continua liberado.
select is(
  (select string_agg(relname, ', ') from objetos
   where relkind = 'r'
     and relname not in ('transacoes_bancarias', 'contas_pluggy', 'conexoes_pluggy')
     and not (has_table_privilege('authenticated', oid, 'SELECT')
      and has_table_privilege('authenticated', oid, 'INSERT')
      and has_table_privilege('authenticated', oid, 'UPDATE')
      and has_table_privilege('authenticated', oid, 'DELETE'))),
  null, 'authenticated mantem leitura e escrita nas tabelas (protegidas pelo RLS)');

-- Tabelas da integracao bancaria: o app so le; escreve por RPC (14.11).
select is(
  (select string_agg(relname, ', ') from objetos
   where relname in ('transacoes_bancarias', 'contas_pluggy', 'conexoes_pluggy')
     and (has_table_privilege('authenticated', oid, 'INSERT')
       or has_table_privilege('authenticated', oid, 'UPDATE')
       or has_table_privilege('authenticated', oid, 'DELETE'))),
  null, 'authenticated nao escreve direto nas tabelas da integracao');

select is(
  (select string_agg(relname, ', ') from objetos
   where relkind = 'v' and not has_table_privilege('authenticated', oid, 'SELECT')),
  null, 'authenticated mantem leitura em todas as views');

select * from finish();
rollback;
