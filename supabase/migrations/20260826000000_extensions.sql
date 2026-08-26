-- pgTAP: usado pelos testes de banco em supabase/tests/database (secao 10 da
-- especificacao -- portoes de calendario e de RLS). Nao e usado por nenhuma
-- view ou funcao de negocio.
create extension if not exists pgtap with schema extensions;
