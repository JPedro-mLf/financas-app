-- RLS (ESPECIFICACAO.md secao 8).
-- Toda tabela: RLS habilitado, policy padrao user_id = auth.uid() para
-- select/insert/update/delete. Este e o ponto critico unico do sistema:
-- se o RLS falhar, o banco esta aberto.

alter table config          enable row level security;
alter table categorias      enable row level security;
alter table recorrentes     enable row level security;
alter table parcelamentos   enable row level security;
alter table avulsos         enable row level security;
alter table execucoes       enable row level security;
alter table descontos_folha enable row level security;
alter table saldos          enable row level security;

-- config
create policy config_select on config for select using (user_id = auth.uid());
create policy config_insert on config for insert with check (user_id = auth.uid());
create policy config_update on config for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy config_delete on config for delete using (user_id = auth.uid());

-- categorias
create policy categorias_select on categorias for select using (user_id = auth.uid());
create policy categorias_insert on categorias for insert with check (user_id = auth.uid());
create policy categorias_update on categorias for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy categorias_delete on categorias for delete using (user_id = auth.uid());

-- recorrentes
create policy recorrentes_select on recorrentes for select using (user_id = auth.uid());
create policy recorrentes_insert on recorrentes for insert with check (user_id = auth.uid());
create policy recorrentes_update on recorrentes for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy recorrentes_delete on recorrentes for delete using (user_id = auth.uid());

-- parcelamentos
create policy parcelamentos_select on parcelamentos for select using (user_id = auth.uid());
create policy parcelamentos_insert on parcelamentos for insert with check (user_id = auth.uid());
create policy parcelamentos_update on parcelamentos for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy parcelamentos_delete on parcelamentos for delete using (user_id = auth.uid());

-- avulsos
create policy avulsos_select on avulsos for select using (user_id = auth.uid());
create policy avulsos_insert on avulsos for insert with check (user_id = auth.uid());
create policy avulsos_update on avulsos for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy avulsos_delete on avulsos for delete using (user_id = auth.uid());

-- execucoes
create policy execucoes_select on execucoes for select using (user_id = auth.uid());
create policy execucoes_insert on execucoes for insert with check (user_id = auth.uid());
create policy execucoes_update on execucoes for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy execucoes_delete on execucoes for delete using (user_id = auth.uid());

-- descontos_folha
create policy descontos_folha_select on descontos_folha for select using (user_id = auth.uid());
create policy descontos_folha_insert on descontos_folha for insert with check (user_id = auth.uid());
create policy descontos_folha_update on descontos_folha for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy descontos_folha_delete on descontos_folha for delete using (user_id = auth.uid());

-- saldos
create policy saldos_select on saldos for select using (user_id = auth.uid());
create policy saldos_insert on saldos for insert with check (user_id = auth.uid());
create policy saldos_update on saldos for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy saldos_delete on saldos for delete using (user_id = auth.uid());
