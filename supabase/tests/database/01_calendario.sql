-- Portao 1 (ESPECIFICACAO.md secao 10): funcoes de calendario contra casos
-- conhecidos, incluindo a janela critica dias 27-30 e meses em que o
-- penultimo dia cai em fim de semana. Datas de referencia sao o ano de 2026
-- (calendario real, verificado independentemente da formula em teste).
begin;

select plan(23);

-- Fixture: config de um usuario de teste, necessaria para fatura_fecha /
-- fatura_vence / ciclo_caixa(credito), que leem a linha de config do usuario.
insert into auth.users (id, email)
values ('11111111-1111-1111-1111-111111111111', 'teste-calendario@local.test');

insert into config (user_id, dia_fechamento, dia_vencimento, horizonte_meses)
values ('11111111-1111-1111-1111-111111111111', 27, 3, 3);

-- data_recebimento: penultimo dia do mes, antecipado quando cai em fim de semana
select is(data_recebimento('2026-01-01'), '2026-01-30'::date, 'jan/2026: penultimo dia e sexta, sem ajuste');
select is(data_recebimento('2026-02-01'), '2026-02-27'::date, 'fev/2026: penultimo dia e sexta, sem ajuste');
select is(data_recebimento('2026-03-01'), '2026-03-30'::date, 'mar/2026: penultimo dia e segunda, sem ajuste');
select is(data_recebimento('2026-04-01'), '2026-04-29'::date, 'abr/2026: penultimo dia e quarta, sem ajuste');
select is(data_recebimento('2026-05-01'), '2026-05-29'::date, 'mai/2026: penultimo dia cai num sabado, antecipa 1 dia para sexta');
select is(data_recebimento('2026-06-01'), '2026-06-29'::date, 'jun/2026: penultimo dia e segunda, sem ajuste');
select is(data_recebimento('2026-07-01'), '2026-07-30'::date, 'jul/2026: penultimo dia e quinta, sem ajuste');
select is(data_recebimento('2026-08-01'), '2026-08-28'::date, 'ago/2026: penultimo dia cai num domingo, antecipa 2 dias para sexta');
select is(data_recebimento('2026-09-01'), '2026-09-29'::date, 'set/2026: penultimo dia e terca, sem ajuste');
select is(data_recebimento('2026-10-01'), '2026-10-30'::date, 'out/2026: penultimo dia e sexta, sem ajuste');
select is(data_recebimento('2026-11-01'), '2026-11-27'::date, 'nov/2026: penultimo dia cai num domingo, antecipa 2 dias para sexta');
select is(data_recebimento('2026-12-01'), '2026-12-30'::date, 'dez/2026: penultimo dia e quarta, sem ajuste');
select is(data_recebimento('2028-02-01'), '2028-02-28'::date, 'fev/2028 (bissexto, 29 dias): penultimo dia e segunda, sem ajuste');

-- ciclo(): decide o mes-rotulo com base no recebimento
select is(ciclo('2026-09-10'::date), '2026-09-01'::date, 'ciclo: antes do recebimento de setembro fica no proprio ciclo de setembro');
select is(ciclo('2026-08-28'::date), '2026-09-01'::date, 'ciclo: no dia exato do recebimento (28/ago) o valor ja pertence ao ciclo seguinte');
select is(ciclo('2026-10-03'::date), '2026-10-01'::date, 'ciclo: 03/out fica no ciclo de outubro (recebimento de out so ocorre em 30/out)');
select is(ciclo('2026-11-03'::date), '2026-11-01'::date, 'ciclo: 03/nov fica no ciclo de novembro (recebimento de nov so ocorre em 27/nov)');

-- Casos de validacao da propria especificacao (secao 4)
select is(ciclo_caixa('2026-09-10'::date, 'credito'::meio_pagamento), '2026-10-01'::date,
  'credito em 10/set fecha 27/set, vence 03/out -> ciclo de outubro');
select is(ciclo_caixa('2026-09-10'::date, 'pix'::meio_pagamento), '2026-09-01'::date,
  'pix em 10/set -> ciclo do proprio setembro, financiado pelo salario de fim de agosto');
select is(ciclo_caixa('2026-09-28'::date, 'credito'::meio_pagamento), '2026-11-01'::date,
  'credito em 28/set (apos o fechamento) fecha 27/out, vence 03/nov -> ciclo de novembro, nao outubro');

-- Janela critica de fechamento (dias 27-30)
select is(fatura_fecha('2026-09-27'::date), '2026-09-27'::date, 'compra no dia exato do fechamento (27) fecha no mesmo mes');
select is(fatura_fecha('2026-09-28'::date), '2026-10-27'::date, 'compra um dia apos o fechamento (28) vai para a fatura do mes seguinte');
select is(fatura_fecha('2026-04-30'::date), '2026-05-27'::date, 'compra no ultimo dia de um mes de 30 dias vai para a fatura seguinte');

select * from finish();

rollback;
