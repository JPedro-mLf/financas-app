-- Fase C da integracao Open Finance (ESPECIFICACAO.md 14.7, ajustada por
-- 14.16/14.17): tabelas. Motor e acoes de revisao na migration seguinte;
-- views e contagem na outra.
--
-- Regra de acesso: o app LE estas tabelas, mas so escreve nelas por RPC
-- (`security definer`, migration seguinte). Por isso as policies de RLS sao so
-- de SELECT -- sem policy de escrita, nenhuma escrita direta do cliente passa,
-- mesmo que um GRANT seja aberto por engano. Excecao: regras_categoria, que o
-- usuario edita na tela de Configuracao.

create extension if not exists pg_trgm with schema extensions;
create extension if not exists unaccent with schema extensions;

create type estado_banco as enum
  ('para_revisar', 'vinculada', 'confirmada', 'ignorada', 'removida');

-- Uma linha por conexao (item) do Meu Pluggy. Alimenta a saude da conexao
-- (14.9): a autorizacao do MeuPluggy vence em 1 ano e, vencida, a API devolve
-- listas vazias sem erro.
create table conexoes_pluggy (
  user_id                 uuid not null default auth.uid() references auth.users on delete cascade,
  item_id                 text not null,
  banco                   text not null,
  status                  text,
  ultima_atualizacao      timestamptz,
  ultima_transacao_em     date,
  consentimento_expira_em timestamptz,
  verificada_em           timestamptz,
  primary key (user_id, item_id)
);

-- Contas de cada conexao. `saldo` alimenta o "Saldo de hoje" automatico
-- (soma das contas BANK, secao 7) numa etapa futura.
create table contas_pluggy (
  user_id         uuid not null default auth.uid() references auth.users on delete cascade,
  conta_pluggy_id text not null,          -- id tecnico da Pluggy, NAO e numero de conta
  item_id         text not null,
  banco           text not null,
  tipo            text not null check (tipo in ('BANK', 'CREDIT')),
  subtipo         text,
  saldo           numeric(12,2),
  saldo_em        timestamptz,
  primary key (user_id, conta_pluggy_id)
);

-- Staging: cada transacao do banco, uma vez (chave_dedupe). Escrita so pela
-- ingestao (Fase D) e pelas funcoes do motor.
create table transacoes_bancarias (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null default auth.uid() references auth.users on delete cascade,
  pluggy_id             text not null,     -- pode MUDAR (a Pluggy apaga e recria)
  -- providerId nao vem pelo MeuPluggy (14.17): hash de conta|data|valor|
  -- descricao + ordinal entre identicas do mesmo dia (calculado na ingestao).
  chave_dedupe          text not null,
  conta_pluggy_id       text not null,
  tipo_conta            text not null check (tipo_conta in ('BANK', 'CREDIT')),
  data                  date not null,
  valor                 numeric(12,2) not null check (valor >= 0),
  -- Sentido ja no vocabulario do app: receita = entrou, despesa = saiu (vem
  -- do campo `type` da Pluggy, normalizado para conta e cartao).
  sentido               tipo_lancamento not null,
  descricao             text not null,
  tipo_operacao         text,              -- operationType: PIX, CARTAO, PAGAMENTO_FATURA...
  meio_inferido         meio_pagamento,
  status_pluggy         text,              -- PENDING | POSTED
  bill_id               text,
  fatura_prevista       text,              -- billForecastDate (AAAA-MM)
  parcela_numero        smallint,
  parcela_total         smallint,
  data_compra_original  date,
  transferencia_propria boolean not null default false,
  estado                estado_banco not null default 'para_revisar',
  vinculo_tipo          text check (vinculo_tipo in ('execucao', 'parcelamento', 'avulso', 'liquidacao')),
  vinculo_id            uuid,
  vinculo_automatico    boolean not null default false,
  -- Execucao como estava antes de um vinculo, para o desfazer restaurar.
  vinculo_anterior      jsonb,
  -- Depois de um desfazer, o motor nao re-casa sozinho (vira so sugestao).
  bloquear_auto         boolean not null default false,
  -- Sugestoes de casamento do motor: [{tipo, id, ciclo?, descricao, valor, data?}].
  -- Com candidato, a transacao NAO conta como provisoria (14.16).
  candidatos            jsonb not null default '[]'::jsonb,
  categoria_sugerida_id uuid references categorias,
  removida_em           timestamptz,
  criada_em             timestamptz not null default now(),
  atualizada_em         timestamptz not null default now(),
  unique (user_id, chave_dedupe),
  check ((estado in ('vinculada', 'confirmada')) = (vinculo_tipo is not null))
);

create index transacoes_bancarias_estado on transacoes_bancarias (user_id, estado);

alter table avulsos
  add column transacao_banco_id uuid unique references transacoes_bancarias on delete set null;

-- Padroes aprendidos a cada confirmacao (14.6): depois de 2 confirmacoes do
-- mesmo padrao, a categoria vira sugestao pre-preenchida. Nunca confirma sozinha.
create table regras_categoria (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null default auth.uid() references auth.users on delete cascade,
  padrao         text not null,
  categoria_id   uuid not null references categorias,
  meio_pagamento meio_pagamento,
  confirmacoes   int not null default 1,
  ativa          boolean not null default true,
  unique (user_id, padrao)
);

-- RLS: mesmo padrao da secao 8.
alter table conexoes_pluggy enable row level security;
alter table contas_pluggy enable row level security;
alter table transacoes_bancarias enable row level security;
alter table regras_categoria enable row level security;

create policy conexoes_pluggy_select on conexoes_pluggy for select using (user_id = auth.uid());
create policy contas_pluggy_select on contas_pluggy for select using (user_id = auth.uid());
create policy transacoes_bancarias_select on transacoes_bancarias for select using (user_id = auth.uid());

create policy regras_categoria_select on regras_categoria for select using (user_id = auth.uid());
create policy regras_categoria_insert on regras_categoria for insert with check (user_id = auth.uid());
create policy regras_categoria_update on regras_categoria for update
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy regras_categoria_delete on regras_categoria for delete using (user_id = auth.uid());

-- GRANTs: anon so le (o RLS devolve zero linhas; ver 02_rls_leak e 05_privilegios).
grant select on conexoes_pluggy, contas_pluggy, transacoes_bancarias, regras_categoria to anon;
grant select on conexoes_pluggy, contas_pluggy, transacoes_bancarias to authenticated;
grant select, insert, update, delete on regras_categoria to authenticated;
