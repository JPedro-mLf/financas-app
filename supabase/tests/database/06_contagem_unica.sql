-- Portao 3 (ESPECIFICACAO.md 14.12): contagem unica das transacoes do banco
-- (migrations 20261128000002..4). Cada transacao entra no saldo NO MAXIMO uma
-- vez, por um so caminho: provisoria, cadastro vinculado ou avulso confirmado.
--
-- Cenario no ciclo de abril/2030 (fecha 27, vence 3): compras no cartao entre
-- 28/02 e 27/03 vencem em 03/04 e caem em abril; Pix de 01 a 28/04 tambem.
-- A prova central e o total do ciclo: so muda quando um gasto passa a contar
-- ou deixa de contar de verdade -- nunca quando so troca de caminho.
begin;

-- Mesmo preambulo dos demais testes (ver 01_calendario.sql).
set role postgres;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(49);

insert into auth.users (id, email) values
  ('66666666-6666-6666-6666-666666666666', 'teste-contagem@local.test'),
  ('77777777-7777-7777-7777-777777777777', 'teste-intruso@local.test');
insert into config (user_id) values
  ('66666666-6666-6666-6666-666666666666'), ('77777777-7777-7777-7777-777777777777');
insert into categorias (id, user_id, nome, tipo) values
  ('c0000000-0000-0000-0000-000000000001', '66666666-6666-6666-6666-666666666666', 'Geral', 'despesa'),
  ('c0000000-0000-0000-0000-000000000002', '66666666-6666-6666-6666-666666666666', 'Assinaturas', 'despesa');

-- Lancamentos manuais ja existentes (como os copiados da producao).
insert into avulsos (id, user_id, data, descricao, tipo, categoria_id, meio_pagamento, valor) values
  ('a0000000-0000-0000-0000-000000000004', '66666666-6666-6666-6666-666666666666', '2030-03-12', 'Mercado', 'despesa', 'c0000000-0000-0000-0000-000000000001', 'credito', 80),
  ('a0000000-0000-0000-0000-00000000005a', '66666666-6666-6666-6666-666666666666', '2030-03-14', 'Farmacia 1', 'despesa', 'c0000000-0000-0000-0000-000000000001', 'credito', 30),
  ('a0000000-0000-0000-0000-00000000005b', '66666666-6666-6666-6666-666666666666', '2030-03-16', 'Farmacia 2', 'despesa', 'c0000000-0000-0000-0000-000000000001', 'credito', 30);

-- Transacoes vindas do banco (o que a ingestao da Fase D vai gravar).
insert into transacoes_bancarias
  (id, user_id, pluggy_id, chave_dedupe, conta_pluggy_id, tipo_conta, data, valor, sentido, descricao,
   tipo_operacao, meio_inferido, parcela_numero, parcela_total, data_compra_original, transferencia_propria, estado)
select x.id::uuid, '66666666-6666-6666-6666-666666666666', 'p-' || x.k, 'k-' || x.k, x.conta, x.tc, x.d::date, x.v,
       x.s::tipo_lancamento, x.descr, x.op, x.meio::meio_pagamento, x.pn, x.pt, x.dco::date, x.tp, x.est::estado_banco
from (values
  ('b0000000-0000-0000-0000-000000000001', 't1',  'cartao', 'CREDIT', '2030-03-10', 100.00, 'despesa', 'LOJA X',              'PAGAMENTO',        'credito', null::int, null::int, null, false, 'para_revisar'),
  ('b0000000-0000-0000-0000-000000000002', 't2',  'conta',  'BANK',   '2030-04-10',  50.00, 'despesa', 'PIX ENVIADO FULANO',  'PIX',              'pix',     null, null, null, null,  'para_revisar'),
  ('b0000000-0000-0000-0000-000000000003', 't3',  'conta',  'BANK',   '2030-04-11',1000.00, 'receita', 'PIX RECEBIDO',        'PIX',              'pix',     null, null, null, null,  'para_revisar'),
  ('b0000000-0000-0000-0000-000000000004', 't4',  'cartao', 'CREDIT', '2030-03-12',  80.00, 'despesa', 'SUPERMERCADO',        'PAGAMENTO',        'credito', null, null, null, false, 'para_revisar'),
  ('b0000000-0000-0000-0000-000000000005', 't5',  'cartao', 'CREDIT', '2030-03-15',  30.00, 'despesa', 'DROGARIA',            'PAGAMENTO',        'credito', null, null, null, false, 'para_revisar'),
  ('b0000000-0000-0000-0000-000000000006', 't6',  'cartao', 'CREDIT', '2030-04-03', 500.00, 'receita', 'PAGAMENTO RECEBIDO',  'PAGAMENTO_FATURA', 'credito', null, null, null, false, 'para_revisar'),
  ('b0000000-0000-0000-0000-000000000007', 't7',  'conta',  'BANK',   '2030-04-03', 500.00, 'despesa', 'PAGTO FATURA CARTAO', 'BOLETO',           'boleto',  null, null, null, false, 'para_revisar'),
  ('b0000000-0000-0000-0000-000000000008', 't8',  'cartao', 'CREDIT', '2030-03-20',  60.00, 'despesa', 'RESTAURANTE',         'PAGAMENTO',        'credito', null, null, null, false, 'para_revisar'),
  ('b0000000-0000-0000-0000-000000000009', 't9',  'cartao', 'CREDIT', '2030-03-05', 200.00, 'despesa', 'TV LOJA 1/2',         'PAGAMENTO',        'credito', 1, 2, '2030-03-05', false, 'para_revisar'),
  ('b0000000-0000-0000-0000-000000000010', 't10', 'conta',  'BANK',   '2030-04-12',  45.00, 'despesa', 'COMPRA DEBITO',       'CARTAO',           'debito',  null, null, null, true,  'para_revisar'),
  ('b0000000-0000-0000-0000-000000000011', 't11', 'cartao', 'CREDIT', '2030-03-21',  70.00, 'despesa', 'SUMIU DO BANCO',      'PAGAMENTO',        'credito', null, null, null, false, 'removida')
) as x(id, k, conta, tc, d, v, s, descr, op, meio, pn, pt, dco, tp, est);

create function pg_temp.total(c date) returns numeric language sql as $$
  select coalesce(sum(case when tipo = 'receita' then valor else -valor end), 0)
  from v_fluxo where user_id = '66666666-6666-6666-6666-666666666666' and ciclo = c;
$$;
create function pg_temp.provisorias() returns text language sql as $$
  select coalesce(string_agg(descricao, ',' order by descricao), '')
  from v_banco_provisorio where user_id = '66666666-6666-6666-6666-666666666666';
$$;
create function pg_temp.estado(i text) returns text language sql as $$
  select estado || coalesce('/' || vinculo_tipo, '') from transacoes_bancarias where id = i::uuid;
$$;

select casar_transacoes_bancarias('66666666-6666-6666-6666-666666666666');

-- Casamento automatico.
select is(pg_temp.estado('b0000000-0000-0000-0000-000000000004'), 'vinculada/avulso',
  'compra no cartao com lancamento manual unico (valor e data) e vinculada sozinha');
select is((select transacao_banco_id from avulsos where id = 'a0000000-0000-0000-0000-000000000004'),
  'b0000000-0000-0000-0000-000000000004'::uuid, 'o avulso aponta para a transacao do banco');
select is(pg_temp.estado('b0000000-0000-0000-0000-000000000006'), 'vinculada/liquidacao',
  'pagamento de fatura no cartao e liquidacao');
select is(pg_temp.estado('b0000000-0000-0000-0000-000000000007'), 'vinculada/liquidacao',
  'o debito na conta que paga a fatura tambem e liquidacao');
select is(pg_temp.estado('b0000000-0000-0000-0000-000000000005'), 'para_revisar',
  'dois lancamentos manuais possiveis: nao casa sozinho');
select is((select jsonb_array_length(candidatos) from transacoes_bancarias where id = 'b0000000-0000-0000-0000-000000000005'),
  2, '...e vira sugestao com os dois candidatos');

-- Quem conta como provisorio: so cartao/debito, sem candidato, nao proprio.
select is(pg_temp.provisorias(), 'LOJA X,RESTAURANTE',
  'provisorias: compras no cartao sem candidato (nao: parcelada, Pix sem terceiro identificado, com candidato, liquidacao, transferencia propria, removida)');

-- Total de abril/2030: manuais (80 + 30 + 30) + provisorias (100 + 60). A
-- parcela da TV nao conta: parceladas vem so dos parcelamentos cadastrados.
select is(pg_temp.total('2030-04-01'), -300.00::numeric,
  'abril: cada gasto conta uma vez (o vinculado conta so pelo avulso manual)');

-- Confirmar uma compra provisoria: troca de caminho, o total nao muda.
set role authenticated;
set request.jwt.claim.sub = '66666666-6666-6666-6666-666666666666';
select confirmar_transacao('b0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001');
set role postgres;
select is(pg_temp.total('2030-04-01'), -300.00::numeric, 'confirmar compra provisoria nao soma duas vezes');
select is(pg_temp.provisorias(), 'RESTAURANTE', '...ela sai das provisorias');
select is((select count(*)::int from v_fluxo where descricao = 'LOJA X' and user_id = '66666666-6666-6666-6666-666666666666'),
  1, '...e aparece uma unica vez no fluxo, como avulso');

-- Confirmar um Pix: passa a contar (antes nao contava).
set role authenticated;
select confirmar_transacao('b0000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000001', null, 'Pix pro Fulano');
set role postgres;
select is(pg_temp.total('2030-04-01'), -350.00::numeric, 'Pix confirmado passa a contar (50), uma vez');

-- Ignorar uma provisoria: deixa de contar.
set role authenticated;
select ignorar_transacao('b0000000-0000-0000-0000-000000000008');
set role postgres;
select is(pg_temp.total('2030-04-01'), -290.00::numeric, 'compra ignorada deixa de contar (60)');

-- Cadastrar o parcelamento depois e re-casar: a parcela troca de caminho.
insert into parcelamentos (id, user_id, descricao, categoria_id, meio_pagamento, data_compra, valor_parcela, num_parcelas)
values ('d0000000-0000-0000-0000-000000000009', '66666666-6666-6666-6666-666666666666', 'TV', 'c0000000-0000-0000-0000-000000000001',
        'credito', '2030-03-05', 200, 2);
select casar_transacoes_bancarias('66666666-6666-6666-6666-666666666666');
select is(pg_temp.estado('b0000000-0000-0000-0000-000000000009'), 'vinculada/parcelamento',
  'parcela casa com o parcelamento cadastrado depois');
select is(pg_temp.total('2030-04-01'), -490.00::numeric, 'abril ganha a 1a parcela pelo cadastro (a do banco nunca contou): uma vez so');
select is(pg_temp.total('2030-05-01'), -200.00::numeric, 'maio ganha a 2a parcela, projetada pelo cadastro');

-- Desfazer a confirmacao: o avulso criado some e a compra volta a provisoria.
set role authenticated;
select desfazer_transacao('b0000000-0000-0000-0000-000000000001');
set role postgres;
select is(pg_temp.estado('b0000000-0000-0000-0000-000000000001'), 'para_revisar', 'desfazer volta para revisar');
select is(pg_temp.total('2030-04-01'), -490.00::numeric, 'desfazer nao muda o total (avulso sai, provisoria volta)');
select is((select count(*)::int from avulsos where transacao_banco_id = 'b0000000-0000-0000-0000-000000000001'),
  0, 'o avulso criado pela confirmacao foi apagado');

-- Apagar no app um avulso vinculado: a transacao volta para revisar e conta
-- como provisoria -- o gasto nao some.
set role authenticated;
delete from avulsos where id = 'a0000000-0000-0000-0000-000000000004';
set role postgres;
select is(pg_temp.estado('b0000000-0000-0000-0000-000000000004'), 'para_revisar',
  'avulso vinculado apagado no app: transacao volta para revisar');
select is(pg_temp.total('2030-04-01'), -490.00::numeric, '...e o gasto continua contado uma vez (agora provisorio)');
select casar_transacoes_bancarias('66666666-6666-6666-6666-666666666666');
select is(pg_temp.estado('b0000000-0000-0000-0000-000000000004'), 'para_revisar',
  'depois de devolvida, o motor nao re-casa sozinho (bloquear_auto)');

-- Reimportacao da mesma transacao: a chave de deduplicacao segura.
insert into transacoes_bancarias (user_id, pluggy_id, chave_dedupe, conta_pluggy_id, tipo_conta, data, valor, sentido, descricao)
values ('66666666-6666-6666-6666-666666666666', 'id-novo-da-pluggy', 'k-t8', 'cartao', 'CREDIT', '2030-03-20', 60, 'despesa', 'RESTAURANTE')
on conflict (user_id, chave_dedupe) do nothing;
select is((select count(*)::int from transacoes_bancarias where chave_dedupe = 'k-t8'), 1,
  'mesma transacao com id novo da Pluggy nao duplica');

-- Recorrente (assinatura no cartao) casa sozinho e marca a execucao como paga.
insert into recorrentes (id, user_id, descricao, tipo, categoria_id, meio_pagamento, valor_previsto, dia_referencia, data_inicio)
values ('e0000000-0000-0000-0000-000000000001', '66666666-6666-6666-6666-666666666666', 'Netflix', 'despesa',
        'c0000000-0000-0000-0000-000000000002', 'credito', 39.90, 5, current_date - 90);
insert into transacoes_bancarias (id, user_id, pluggy_id, chave_dedupe, conta_pluggy_id, tipo_conta, data, valor, sentido, descricao, tipo_operacao, meio_inferido)
values ('b0000000-0000-0000-0000-000000000012', '66666666-6666-6666-6666-666666666666', 'p-t12', 'k-t12', 'cartao', 'CREDIT',
        current_date, 39.90, 'despesa', 'NETFLIX.COM', 'PAGAMENTO', 'credito');
select casar_transacoes_bancarias('66666666-6666-6666-6666-666666666666');
select is(pg_temp.estado('b0000000-0000-0000-0000-000000000012'), 'vinculada/execucao', 'assinatura casa com o recorrente');
select is((select count(*)::int from v_fluxo
           where user_id = '66666666-6666-6666-6666-666666666666'
             and ciclo = ciclo_caixa(current_date, 'credito', '66666666-6666-6666-6666-666666666666')
             and (descricao ilike '%netflix%')),
  1, 'a assinatura aparece uma vez no ciclo (pelo recorrente, nao provisoria)');
select is((select status::text from execucoes where recorrente_id = 'e0000000-0000-0000-0000-000000000001'), 'pago',
  'execucao do ciclo marcada como paga');

-- ===== Ajustes da revisao com dados reais (migration 20261128000006)

-- Pix com terceiro identificado conta na hora; para si mesmo, nao.
insert into transacoes_bancarias (id, user_id, pluggy_id, chave_dedupe, conta_pluggy_id, tipo_conta, data, valor, sentido, descricao, tipo_operacao, meio_inferido, transferencia_propria)
values
  ('b0000000-0000-0000-0000-000000000013', '66666666-6666-6666-6666-666666666666', 'p-t13', 'k-t13', 'conta', 'BANK', '2030-04-15', 25, 'despesa', 'PIX ENVIADO TERCEIRO', 'PIX', 'pix', false),
  ('b0000000-0000-0000-0000-000000000014', '66666666-6666-6666-6666-666666666666', 'p-t14', 'k-t14', 'conta', 'BANK', '2030-04-15', 40, 'despesa', 'PIX PARA MIM', 'PIX', 'pix', true),
  ('b0000000-0000-0000-0000-000000000015', '66666666-6666-6666-6666-666666666666', 'p-t15', 'k-t15', 'conta', 'BANK', '2030-04-16', 70, 'receita', 'PIX RECEBIDO TERCEIRO', 'PIX', 'pix', false);
select casar_transacoes_bancarias('66666666-6666-6666-6666-666666666666');
select is(pg_temp.provisorias(), 'LOJA X,PIX ENVIADO TERCEIRO,PIX RECEBIDO TERCEIRO,SUPERMERCADO',
  'Pix com terceiro identificado conta (entrada e saida); para si mesmo e desconhecido, nao');
select is(pg_temp.total('2030-04-01'), -445.00::numeric, 'abril: -25 e +70 dos Pix com terceiros, uma vez cada');

-- Parceladas: nunca contam pelo banco; ficam so para conferencia.
select is((parcela_do_texto('SERGIO S 6/10')).total, 10, 'parcela no texto: 6/10 -> total 10');
select is((parcela_do_texto('PAGTO 21/11/2026')).total, null, 'data no texto (21/11) nao vira parcela');
select is((parcela_do_texto('LOJA 1/1')).total, null, 'compra 1/1 nao e parcelada');
insert into transacoes_bancarias (id, user_id, pluggy_id, chave_dedupe, conta_pluggy_id, tipo_conta, data, valor, sentido, descricao, tipo_operacao, meio_inferido, tipo_pagamento)
values ('b0000000-0000-0000-0000-000000000016', '66666666-6666-6666-6666-666666666666', 'p-t16', 'k-t16', 'cartao', 'CREDIT',
        '2030-03-08', 99, 'despesa', 'GELADEIRA', 'PAGAMENTO', 'credito', 'INSTALLMENT');
select casar_transacoes_bancarias('66666666-6666-6666-6666-666666666666');
select is((select count(*)::int from v_para_revisar where id = 'b0000000-0000-0000-0000-000000000016'), 0,
  'parcelada sem cadastro nao aparece na lista comum nem conta no saldo');
select is((select situacao from v_parceladas_banco where id = 'b0000000-0000-0000-0000-000000000016'), 'sem_cadastro',
  '...aparece no filtro Parceladas como "sem cadastro"');

-- Nome no banco aprendido: Apple cadastrada 19,99, cobrada 19,90 como APPLE.COM/BILL.
insert into recorrentes (id, user_id, descricao, tipo, categoria_id, meio_pagamento, valor_previsto, dia_referencia, data_inicio)
values ('e0000000-0000-0000-0000-000000000002', '66666666-6666-6666-6666-666666666666', 'Assinatura Apple Layanne', 'despesa',
        'c0000000-0000-0000-0000-000000000002', 'credito', 19.99, 21, current_date - 90);
insert into transacoes_bancarias (id, user_id, pluggy_id, chave_dedupe, conta_pluggy_id, tipo_conta, data, valor, sentido, descricao, tipo_operacao, meio_inferido)
values ('b0000000-0000-0000-0000-000000000017', '66666666-6666-6666-6666-666666666666', 'p-t17', 'k-t17', 'cartao', 'CREDIT',
        current_date, 19.90, 'despesa', 'APPLE.COM/BILL', 'PAGAMENTO', 'credito');
select casar_transacoes_bancarias('66666666-6666-6666-6666-666666666666');
select is(pg_temp.estado('b0000000-0000-0000-0000-000000000017'), 'para_revisar',
  'Apple: valor diferente e descricao pouco parecida -- nao casa sozinha na primeira vez');
set role authenticated;
select vincular_transacao('b0000000-0000-0000-0000-000000000017', 'recorrente', 'e0000000-0000-0000-0000-000000000002');
set role postgres;
insert into transacoes_bancarias (id, user_id, pluggy_id, chave_dedupe, conta_pluggy_id, tipo_conta, data, valor, sentido, descricao, tipo_operacao, meio_inferido)
values ('b0000000-0000-0000-0000-000000000018', '66666666-6666-6666-6666-666666666666', 'p-t18', 'k-t18', 'cartao', 'CREDIT',
        current_date + 31, 19.90, 'despesa', 'APPLE.COM/BILL', 'PAGAMENTO', 'credito');
select casar_transacoes_bancarias('66666666-6666-6666-6666-666666666666');
select is((select nome_banco from recorrentes where id = 'e0000000-0000-0000-0000-000000000002'), 'apple com bill',
  'o vinculo manual ensinou o nome no banco');
select is(pg_temp.estado('b0000000-0000-0000-0000-000000000018'), 'vinculada/execucao',
  'no mes seguinte a Apple casa sozinha pelo nome, mesmo com valor diferente');

-- Envelope do estimado: conta so o que falta gastar na categoria.
insert into categorias (id, user_id, nome, tipo)
values ('c0000000-0000-0000-0000-000000000003', '66666666-6666-6666-6666-666666666666', 'Transporte', 'despesa');
insert into recorrentes (id, user_id, descricao, tipo, categoria_id, meio_pagamento, valor_previsto, estimado, dia_referencia, data_inicio)
values ('e0000000-0000-0000-0000-000000000003', '66666666-6666-6666-6666-666666666666', 'Combustivel', 'despesa',
        'c0000000-0000-0000-0000-000000000003', 'pix', 350, true, 10, current_date - 100);
insert into avulsos (user_id, data, descricao, tipo, categoria_id, meio_pagamento, valor)
values ('66666666-6666-6666-6666-666666666666', current_date, 'Posto', 'despesa', 'c0000000-0000-0000-0000-000000000003', 'pix', 120);
select is((select valor from v_recorrentes_ciclo where origem_id = 'e0000000-0000-0000-0000-000000000003' and ciclo = ciclo(current_date)),
  230.00::numeric, 'envelope no ciclo atual: 350 previstos - 120 ja gastos na categoria');
select is((select valor || '/' || status from v_recorrentes_ciclo
           where origem_id = 'e0000000-0000-0000-0000-000000000003'
             and ciclo = (ciclo(current_date) - interval '1 month')::date),
  '0.00/cancelado', 'ciclo que ja passou: o que sobrou do envelope zera');
select is((select valor from v_recorrentes_ciclo
           where origem_id = 'e0000000-0000-0000-0000-000000000003'
             and ciclo = (ciclo(current_date) + interval '1 month')::date),
  350.00::numeric, 'ciclo futuro: envelope cheio');

-- ===== Transferencias do proprio CPF e juros (migration 20261128000007)
create temp table total_antes as select pg_temp.total('2030-04-01') as v;
insert into transacoes_bancarias (id, user_id, pluggy_id, chave_dedupe, conta_pluggy_id, tipo_conta, data, valor, sentido, descricao, tipo_operacao, meio_inferido, transferencia_propria)
values
  ('b0000000-0000-0000-0000-000000000019', '66666666-6666-6666-6666-666666666666', 'p-t19', 'k-t19', 'conta',  'BANK', '2030-04-20', 300,   'despesa', 'PIX PARA POUPANCA',  'PIX', 'pix', true),
  ('b0000000-0000-0000-0000-000000000020', '66666666-6666-6666-6666-666666666666', 'p-t20', 'k-t20', 'conta2', 'BANK', '2030-04-20', 300,   'receita', 'PIX RECEBIDO DE MIM', 'PIX', 'pix', true),
  ('b0000000-0000-0000-0000-000000000021', '66666666-6666-6666-6666-666666666666', 'p-t21', 'k-t21', 'conta',  'BANK', '2030-04-22', 500,   'receita', 'PIX DO BB',           'PIX', 'pix', true),
  ('b0000000-0000-0000-0000-000000000022', '66666666-6666-6666-6666-666666666666', 'p-t22', 'k-t22', 'conta',  'BANK', '2030-04-23', 12.34, 'despesa', 'JUROS CHEQUE ESPECIAL', 'ENCARGOS_JUROS_CHEQUE_ESPECIAL', 'debito', null);
select casar_transacoes_bancarias('66666666-6666-6666-6666-666666666666');
select is(pg_temp.estado('b0000000-0000-0000-0000-000000000019'), 'vinculada/interna',
  'saida para si com entrada igual em outra conta conectada: transferencia interna');
select is(pg_temp.estado('b0000000-0000-0000-0000-000000000020'), 'vinculada/interna', '...as duas pontas do par');
select is(pg_temp.total('2030-04-01'), (select v from total_antes) + 500 - 12.34,
  'interna nao conta; entrada do proprio CPF sem par (conta nao conectada, ex. BB) conta; juros contam');
select is((select conta_no_saldo from v_para_revisar where id = 'b0000000-0000-0000-0000-000000000014'), false,
  'saida para si sem par fica para revisar, fora do saldo');
set role authenticated;
select ignorar_transferencias_proprias();
set role postgres;
select is(pg_temp.estado('b0000000-0000-0000-0000-000000000014'), 'ignorada',
  'ignorar todas para mim: so as saidas sem par');
set role authenticated;
select desfazer_transacao('b0000000-0000-0000-0000-000000000019');
set role postgres;
select is(pg_temp.estado('b0000000-0000-0000-0000-000000000020'), 'para_revisar',
  'desfazer uma interna devolve as duas pontas');

-- Seguranca: outro usuario nao age sobre transacao alheia.
set role authenticated;
set request.jwt.claim.sub = '77777777-7777-7777-7777-777777777777';
select throws_ok($$ select confirmar_transacao('b0000000-0000-0000-0000-000000000005', 'c0000000-0000-0000-0000-000000000001') $$,
  'P0001', 'transacao nao encontrada ou ja revisada', 'intruso nao confirma transacao de outro usuario');
select throws_ok($$ select casar_transacoes_bancarias('66666666-6666-6666-6666-666666666666') $$,
  'P0001', 'sem permissao para agir por outro usuario', 'intruso nao roda o motor por outro usuario');
select throws_ok($$ insert into transacoes_bancarias (pluggy_id, chave_dedupe, conta_pluggy_id, tipo_conta, data, valor, sentido, descricao)
                    values ('x', 'x', 'x', 'BANK', '2030-01-01', 1, 'despesa', 'x') $$,
  '42501', null, 'cliente nao insere direto na staging');
set request.jwt.claim.sub = '66666666-6666-6666-6666-666666666666';
select throws_ok($$ update avulsos set transacao_banco_id = 'b0000000-0000-0000-0000-000000000005'
                    where id = 'a0000000-0000-0000-0000-00000000005a' $$,
  'P0001', 'transacao_banco_id so e definido pela revisao bancaria', 'cliente nao vincula avulso direto');
set role postgres;

select * from finish();
rollback;
