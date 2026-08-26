-- GRANTs de tabela (secao 8). Por padrao, tabelas novas no Supabase NAO sao
-- expostas as roles da API sem GRANT explicito. Precisamos que `anon` consiga
-- de fato consultar as tabelas -- e nao ver nada -- para que o teste de
-- vazamento da secao 8 prove o que promete provar (defesa e o RLS, nao a
-- ausencia de permissao). `authenticated` recebe os privilegios que o app usa.

grant usage on schema public to anon, authenticated;

grant select on
  config, categorias, recorrentes, parcelamentos, avulsos,
  execucoes, descontos_folha, saldos
to anon;

grant select, insert, update, delete on
  config, categorias, recorrentes, parcelamentos, avulsos,
  execucoes, descontos_folha, saldos
to authenticated;

grant select on v_parcelas, v_recorrentes_ciclo, v_avulsos, v_fluxo,
  v_resumo_ciclo, v_previsao, v_alertas
to authenticated;

-- As views sao security_invoker: quando `authenticated` consulta uma view que
-- chama estas funcoes internamente (ex.: v_parcelas chama ciclo_caixa), o
-- Postgres verifica o privilegio de EXECUTE contra a role que fez a consulta,
-- nao contra o dono da view. Sem isso, toda consulta as views falha com
-- permissao negada.
grant execute on function data_recebimento(date) to authenticated;
grant execute on function ciclo(date) to authenticated;
grant execute on function fatura_fecha(date) to authenticated;
grant execute on function fatura_vence(date) to authenticated;
grant execute on function ciclo_caixa(date, meio_pagamento) to authenticated;
