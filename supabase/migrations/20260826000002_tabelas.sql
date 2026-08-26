-- Modelo de dados (ESPECIFICACAO.md secao 6)
-- user_id sempre com "default auth.uid()", nunca preenchido pelo cliente (secao 8).

create table config (
  user_id          uuid primary key references auth.users on delete cascade default auth.uid(),
  dia_fechamento   smallint not null default 27,
  dia_vencimento   smallint not null default 3,
  horizonte_meses  smallint not null default 3 check (horizonte_meses between 1 and 24)
);

create table categorias (
  id      uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users on delete cascade default auth.uid(),
  nome    text not null,
  tipo    tipo_lancamento not null,
  ativa   boolean not null default true,
  unique (user_id, nome)
);

-- Lancamentos recorrentes: o CADASTRO, atemporal
create table recorrentes (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users on delete cascade default auth.uid(),
  descricao       text not null,
  tipo            tipo_lancamento not null,
  categoria_id    uuid not null references categorias,
  meio_pagamento  meio_pagamento not null,
  valor_previsto  numeric(12,2) not null,
  estimado        boolean not null default false,   -- true = "custo virtual"
  dia_referencia  smallint not null check (dia_referencia between 1 and 31),
  data_inicio     date not null,
  data_fim        date,                              -- null = indefinido
  ativo           boolean not null default true
);

-- Parcelamentos: guarda a PARCELA, nunca o total
create table parcelamentos (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users on delete cascade default auth.uid(),
  descricao       text not null,
  categoria_id    uuid not null references categorias,
  meio_pagamento  meio_pagamento not null,    -- critico: distingue cartao de debito em conta
  data_compra     date not null,
  valor_parcela   numeric(12,2) not null,
  num_parcelas    smallint not null check (num_parcelas > 0)
);

-- Lancamentos avulsos (pontuais)
create table avulsos (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users on delete cascade default auth.uid(),
  data            date not null,
  descricao       text not null,
  tipo            tipo_lancamento not null,
  categoria_id    uuid not null references categorias,
  meio_pagamento  meio_pagamento not null,
  valor           numeric(12,2) not null
);

-- Realizacao por ciclo: status e valor efetivo dos recorrentes
create table execucoes (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users on delete cascade default auth.uid(),
  ciclo           date not null,
  recorrente_id   uuid not null references recorrentes,
  valor_realizado numeric(12,2),             -- null = ainda usa o previsto
  status          status_execucao not null default 'pendente',
  data_efetiva    date,
  unique (user_id, ciclo, recorrente_id)
);

-- Descontos em folha (salario bruto -> liquido)
create table descontos_folha (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users on delete cascade default auth.uid(),
  descricao   text not null,
  percentual  numeric(6,4),                  -- ex.: 8.4500 para INSS
  valor_fixo  numeric(12,2),                 -- alternativa ao percentual
  ativo       boolean not null default true,
  check (num_nonnulls(percentual, valor_fixo) = 1)
);

-- Conciliacao de saldo
create table saldos (
  user_id       uuid not null references auth.users on delete cascade default auth.uid(),
  ciclo         date not null,
  valor_apurado numeric(12,2) not null,
  primary key (user_id, ciclo)
);
