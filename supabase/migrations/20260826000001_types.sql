-- Tipos enumerados (ESPECIFICACAO.md secao 6)

create type tipo_lancamento as enum ('receita', 'despesa');
create type meio_pagamento  as enum ('credito','debito','pix','dinheiro','boleto','folha');
create type status_execucao as enum ('previsto','pendente','pago','cancelado');
