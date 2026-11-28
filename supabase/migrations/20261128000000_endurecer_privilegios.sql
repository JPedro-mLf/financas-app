-- Segunda tranca de seguranca (ESPECIFICACAO.md secoes 8 e 14.18).
--
-- O acesso aos dados tem duas camadas em serie: o GRANT (a role pode, em
-- principio, ler/escrever na tabela?) e o RLS (quais linhas: so as do proprio
-- usuario). Os projetos Supabase mais antigos (como o de producao) dao ao
-- `anon` INSERT/UPDATE/DELETE/TRUNCATE em tudo por padrao; so o RLS segurava
-- a escrita sem sessao. Esta migration fecha a camada de fora, deixando cada
-- role com o minimo que o app usa:
--
--   anon          -> SELECT nas tabelas (o teste de vazamento 02_rls_leak prova
--                    que o RLS devolve zero linhas; o keepalive le categorias).
--                    Nada nas views, nada de escrita.
--   authenticated -> SELECT/INSERT/UPDATE/DELETE nas tabelas (sujeito ao RLS);
--                    so SELECT nas views.
--   ninguem       -> TRUNCATE, REFERENCES, TRIGGER, MAINTAIN (TRUNCATE nem passa
--                    pelo RLS; o app nunca usa nenhum deles).
--
-- service_role nao muda (so usada pelo painel e, na v2, pelas Edge Functions).

revoke insert, update, delete, truncate, references, trigger, maintain
  on all tables in schema public from anon;
revoke truncate, references, trigger, maintain
  on all tables in schema public from authenticated;

-- Views: leitura apenas para `authenticated`; `anon` nao precisa de nenhuma.
do $$
declare
  v record;
begin
  for v in
    select c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'v'
  loop
    execute format('revoke all on public.%I from anon', v.relname);
    execute format('revoke insert, update, delete on public.%I from authenticated', v.relname);
  end loop;
end
$$;

-- Tabelas e views criadas daqui para frente pelas migrations (role postgres)
-- ja nascem sem esses privilegios. Os GRANTs que o app precisa continuam
-- explicitos em cada migration, como ja era a regra da secao 8.
alter default privileges for role postgres in schema public
  revoke insert, update, delete, truncate, references, trigger, maintain on tables from anon;
alter default privileges for role postgres in schema public
  revoke truncate, references, trigger, maintain on tables from authenticated;
