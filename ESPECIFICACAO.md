# Especificação — App de Controle Financeiro Pessoal

> Documento de premissas e requisitos. Escrito antes do código, deliberadamente.
> Serve como contrato do projeto: se algo aqui estiver errado, corrija **este arquivo**
> antes de corrigir o código.

---

## 1. Objetivo

Substituir uma planilha Excel/VBA de controle orçamentário pessoal por um sistema com:

- **Entrada de dados pelo celular**, rápida, de qualquer lugar.
- **Banco de dados online** como fonte única da verdade.
- **Motor de cálculo dentro do banco** (previsões, saldos, competência de caixa).
- **Resumo simples no celular** e **análise profunda no Power BI Desktop**.

Usuário único. Não é um produto multi-tenant, mas a modelagem já prevê `user_id`
porque é o que habilita o Row Level Security.

---

## 2. Restrições inegociáveis

| # | Restrição | Consequência de projeto |
|---|---|---|
| R1 | **Custo zero permanente**, sem risco de cobrança surpresa | Somente camadas gratuitas sem cartão cadastrado |
| R2 | **Segurança dos dados é prioridade nº 1** | RLS obrigatório em toda tabela; MFA no login |
| R3 | **Nenhum dado que permita dano financeiro** | Proibido armazenar nº de conta, nº de cartão, CPF, senhas |
| R4 | Deve durar anos sem manutenção pesada | Regras de negócio centralizadas em funções SQL, não espalhadas |

### Sobre R3 — regra de design, não de configuração

O pior cenário de vazamento deste banco deve ser **constrangimento, nunca fraude**.
Nenhuma coluna que armazene identificador bancário, documento ou credencial pode
existir no schema. Cartões são referenciados apenas por apelido, se um dia forem.

### Sobre criptografia

Criptografia de coluna no banco foi **avaliada e descartada**:

- O motor de cálculo vive em views SQL. Views precisam ler valores em claro para somar.
- Se o banco consegue decifrar sozinho, a chave está no banco — não há ganho real.
- O `pgsodium` / Transparent Column Encryption está em depreciação no Supabase.

O que efetivamente protege, e é obrigatório:

1. RLS habilitado em **todas** as tabelas, com policy `user_id = auth.uid()`.
2. Senha forte e única + MFA (TOTP) no Supabase Auth.
3. Criptografia em repouso e em trânsito (padrão da plataforma).
4. A chave `anon` pode ser pública **porque** o RLS a torna inútil sem login.
   Se o RLS falhar, o banco está aberto. É o ponto crítico único do sistema.

**Fase 2, opcional:** criptografia client-side apenas do campo `descricao`,
mantendo valores e categorias em claro. Preserva cálculos e Power BI.
Não implementar na v1.

---

## 3. Arquitetura

```
App PWA (celular)          →  entrada de dados
   ↓ HTTPS + Supabase JS
Supabase PostgreSQL        →  tabelas + Auth + RLS
   ↓
Views e funções SQL        →  motor de cálculo (competência, previsão)
   ↓                    ↘
Resumo no celular      Power BI Desktop (conexão PostgreSQL)
```

| Camada | Tecnologia | Custo |
|---|---|---|
| Banco + Auth | Supabase Free (PostgreSQL) | R$ 0 |
| Front-end | PWA estática, GitHub Pages | R$ 0 |
| Anti-pausa | GitHub Actions (cron diário) | R$ 0 |
| BI | Power BI Desktop → conector PostgreSQL | R$ 0 |

**Princípio arquitetural central:** nenhum cálculo financeiro ocorre no front-end.
Celular e Power BI consomem os mesmos números, produzidos pelas mesmas views.
Divergência entre app e BI torna-se estruturalmente impossível.

---

## 4. O ciclo financeiro (regra de negócio central)

O mês financeiro do usuário **não é o mês do calendário**. Ele começa no dia em que
o salário cai.

### Parâmetros confirmados

| Parâmetro | Valor |
|---|---|
| Dia de recebimento | Penúltimo dia do mês; se cair em sábado ou domingo, antecipa para a sexta anterior |
| Fechamento da fatura | Dia 27 (cartões fecham 27 ou 28; adota-se o mais cedo para todos) |
| Vencimento da fatura | Dia 03 do mês seguinte (a maioria vence 05, um vence 03; adota-se 03 para todos) |

### Regra de competência de caixa

| Tipo de lançamento | Ciclo em que pesa no bolso |
|---|---|
| Receita | `ciclo(data)` |
| Despesa em pix / débito / dinheiro / boleto | `ciclo(data)` |
| Despesa no crédito | `ciclo(fatura_vence(data))` |

Validação contra o raciocínio original do usuário:

- Compra no crédito em 10/set → fecha 27/set → vence 03/out → ciclo de outubro.
  O salário do fim de setembro também cai no ciclo de outubro. **Batem.**
- Pix em 10/set → ciclo de setembro, financiado pelo salário do fim de agosto.
  É o "pix deste mês usa o que sobrou do mês anterior". **Bate.**
- Compra no crédito em 28/set (após o fechamento, antes do salário) → fecha 27/out
  → vence 03/nov → ciclo de novembro. Esta é a janela que uma regra simplificada
  de "+1 mês" erraria. É por isso que a versão geral é obrigatória.

> **Nota histórica:** a planilha antiga usava uma regra de "antepenúltimo dia"
> (`>= FIMMÊS-2`) para decidir a virada da fatura. Essa regra era um remendo para
> a ausência do conceito de ciclo, e apresentava divergência entre a intenção
> documentada (2 dias) e a implementação (3 dias). Com o ciclo formalizado, ela
> deixa de existir. **Não reintroduzir.**

---

## 5. Funções de calendário

```sql
-- Data de recebimento do salário em um dado mês
create or replace function data_recebimento(mes date)
returns date language sql immutable as $$
  select case extract(isodow from d)
           when 6 then d - 1   -- sábado  -> sexta anterior
           when 7 then d - 2   -- domingo -> sexta anterior
           else d
         end
  from (select (date_trunc('month', mes) + interval '1 month - 2 days')::date as d) t;
$$;

-- Ciclo ao qual uma data de caixa pertence.
-- Retorna o primeiro dia do MÊS-RÓTULO do ciclo.
create or replace function ciclo(d date)
returns date language sql immutable as $$
  select case when d >= data_recebimento(d)
              then (date_trunc('month', d) + interval '1 month')::date
              else  date_trunc('month', d)::date
         end;
$$;

-- Data de fechamento da fatura que captura uma compra
create or replace function fatura_fecha(compra date)
returns date language sql stable as $$
  select case when extract(day from compra) <= c.dia_fechamento
              then  date_trunc('month', compra)::date + (c.dia_fechamento - 1)
              else (date_trunc('month', compra) + interval '1 month')::date
                     + (c.dia_fechamento - 1)
         end
  from config c;
$$;

-- Vencimento da fatura que captura uma compra
create or replace function fatura_vence(compra date)
returns date language sql stable as $$
  select (date_trunc('month', fatura_fecha(compra)) + interval '1 month')::date
         + (c.dia_vencimento - 1)
  from config c;
$$;

-- Ciclo de caixa de qualquer lançamento
create or replace function ciclo_caixa(d date, meio meio_pagamento)
returns date language sql stable as $$
  select case when meio = 'credito' then ciclo(fatura_vence(d))
              else ciclo(d) end;
$$;
```

> **Premissa embutida:** `dia_vencimento < dia_fechamento` (03 < 27), portanto o
> vencimento cai sempre no mês seguinte ao fechamento. Se isso mudar, revisar
> `fatura_vence`.

### Intervalo de datas de um ciclo (acrescentado em uso real)

As funções acima dizem a qual ciclo uma data pertence, mas não o contrário:
qual intervalo de datas um ciclo cobre. Isso passou a ser necessário quando o
app precisou exibir "de quando até quando" vai o mês financeiro em exibição.

```sql
create or replace function ciclo_inicio(c date)
returns date language sql immutable as $$
  select data_recebimento((date_trunc('month', c) - interval '1 month')::date);
$$;

create or replace function ciclo_fim(c date)
returns date language sql immutable as $$
  select data_recebimento(c) - 1;
$$;
```

O ciclo rotulado `C` começa no salário que o abriu -- `data_recebimento` do mês
anterior -- e termina na véspera do próximo recebimento. Conferindo com o
exemplo da seção 4: o salário de 28/ago/2026 cai no ciclo de setembro, então
`ciclo_inicio('2026-09-01') = 2026-08-28` e `ciclo_fim('2026-09-01') =
2026-09-28`. Ciclos consecutivos ficam encostados, sem buraco nem sobreposição.

---

## 6. Modelo de dados

### Tipos

```sql
create type tipo_lancamento as enum ('receita', 'despesa');
create type meio_pagamento  as enum ('credito','debito','pix','dinheiro','boleto','folha');
create type status_execucao as enum ('previsto','pendente','pago','cancelado');
```

### Tabelas

```sql
-- Configuração do usuário (uma linha)
config (
  user_id uuid primary key references auth.users,
  dia_fechamento   smallint not null default 27,
  dia_vencimento   smallint not null default 3,
  horizonte_meses  smallint not null default 3   -- 1 a 24
)

categorias (
  id uuid primary key, user_id uuid not null,
  nome text not null, tipo tipo_lancamento not null,
  ativa boolean not null default true,
  unique (user_id, nome)
)

-- Lançamentos recorrentes: o CADASTRO, atemporal
recorrentes (
  id uuid primary key, user_id uuid not null,
  descricao text not null,
  tipo tipo_lancamento not null,
  categoria_id uuid not null references categorias,
  meio_pagamento meio_pagamento not null,
  valor_previsto numeric(12,2) not null,
  estimado boolean not null default false,   -- true = "custo virtual"
  dia_referencia smallint not null,          -- dia do pagamento/recebimento
  data_inicio date not null,
  data_fim date,                             -- null = indefinido
  ativo boolean not null default true
)

-- Parcelamentos: guarda a PARCELA, não o total
parcelamentos (
  id uuid primary key, user_id uuid not null,
  descricao text not null,
  categoria_id uuid not null references categorias,
  meio_pagamento meio_pagamento not null,    -- crítico: distingue cartão de débito em conta
  data_compra date not null,
  valor_parcela numeric(12,2) not null,
  num_parcelas smallint not null check (num_parcelas > 0)
)

-- Lançamentos avulsos (pontuais)
avulsos (
  id uuid primary key, user_id uuid not null,
  data date not null,
  descricao text not null,
  tipo tipo_lancamento not null,
  categoria_id uuid not null references categorias,
  meio_pagamento meio_pagamento not null,
  valor numeric(12,2) not null
)

-- Realização por ciclo: status e valor efetivo dos recorrentes
execucoes (
  id uuid primary key, user_id uuid not null,
  ciclo date not null,
  recorrente_id uuid not null references recorrentes,
  valor_realizado numeric(12,2),             -- null = ainda usa o previsto
  status status_execucao not null default 'pendente',
  data_efetiva date,
  unique (user_id, ciclo, recorrente_id)
)

-- Descontos em folha (salário bruto -> líquido)
descontos_folha (
  id uuid primary key, user_id uuid not null,
  descricao text not null,
  percentual numeric(6,4),                   -- ex.: 8.4500 para INSS
  valor_fixo numeric(12,2),                  -- alternativa ao percentual
  ativo boolean not null default true,
  check (num_nonnulls(percentual, valor_fixo) = 1)
)

-- Conciliação de saldo
saldos (
  user_id uuid not null, ciclo date not null,
  valor_apurado numeric(12,2) not null,
  primary key (user_id, ciclo)
)
```

### Decisões de modelagem, com justificativa

- **Não existe tabela de previsão.** Previsão é resultado, não dado. Armazenar
  previsão gera número desatualizado. É uma view.
- **Colunas calculadas foram removidas.** A planilha antiga mantinha à mão
  `Parcelas Lançadas`, `Status`, `Status Próximo Mês`, `Finaliza em` e o sufixo
  `(3/10)` na descrição. Tudo isso deriva de `data_compra` + `num_parcelas` e
  passa a ser gerado por view.
- **Guarda-se `valor_parcela`, nunca `valor_total`.** A parcela é o que o cartão
  efetivamente cobra; dividir um total por N cria centavo de arredondamento que
  não bate com a fatura. O total é derivado.
- **`meio_pagamento` também em `parcelamentos`.** Um financiamento debitado em
  conta e uma compra parcelada no cartão têm competências de caixa diferentes.
  Tratá-los igual desloca o financiamento em um mês, todo mês.
- **Não há tabela de bancos ou cartões na v1.** Requisito explícito do usuário:
  distinguir apenas o meio de compra.
- **`estimado`** marca os "custos virtuais" (combustível, manutenção do carro).
  A previsão usa `valor_previsto`; quando `execucoes.valor_realizado` existe, ele
  prevalece. O usuário deixa de apagar linhas manualmente e passa a acumular
  histórico — após alguns ciclos, a estimativa pode ser calibrada pelo próprio dado.
- **Salário bruto com descontos em folha.** Decisão do usuário. Evita o problema
  da planilha antiga, onde INSS e seguro de vida estavam categorizados como
  "Salário Folha Normal", misturando origem com natureza e poluindo a análise
  por categoria.

### Dado conhecido

- INSS: **8,45%** do salário bruto. Demais descontos a cadastrar.

---

## 7. Views (motor de cálculo)

```sql
-- Expande cada parcelamento em uma linha por parcela
create view v_parcelas as
select p.id as origem_id, 'parcelamento' as origem, p.user_id,
       p.descricao, p.categoria_id, p.meio_pagamento,
       n as numero_parcela, p.num_parcelas,
       p.valor_parcela as valor,
       (ciclo_caixa(p.data_compra, p.meio_pagamento)
         + (n - 1) * interval '1 month')::date as ciclo
from parcelamentos p
cross join lateral generate_series(1, p.num_parcelas) as n;
```

Demais views (implementadas na v1 — a especificação original deixava o SQL
em aberto; o design abaixo é o que foi construído e testado):

| View | Responsabilidade |
|---|---|
| `v_recorrentes_ciclo` | Expande recorrentes ativos por ciclo, aplicando `execucoes` quando houver |
| `v_avulsos` | Normaliza avulsos para o formato comum |
| `v_fluxo` | `union all` das três acima — a tabela-fato que o Power BI consome |
| `v_resumo_ciclo` | Receitas, despesas, saldo do ciclo, previsto vs. realizado |
| `v_previsao` | Saldo acumulado projetado ao longo de `horizonte_meses`, só pra frente (lê de `v_saldo_acumulado`, juros incluídos) |
| `v_alertas` | Sinaliza saldo negativo previsto dentro do horizonte |
| `v_saldo_acumulado` | Saldo acumulado até qualquer ciclo (passado, atual ou futuro), ancorado no último saldo apurado; nos ciclos futuros, desconta juros de cheque especial (`juros_cheque_especial`) |
| `v_reserva_estimados` | Reserva acumulada dos itens `estimado`: soma de previsto − realizado nos ciclos já confirmados |
| `v_gastos_por_categoria` | Total por categoria, por ciclo e por tipo — alimenta o ranking de gastos do Resumo |

Decisões de design tomadas na implementação:

- **Toda view derivada expõe `categoria_nome`, não só `categoria_id`.** Um uuid
  não diz nada para quem lê a tabela crua — no Table Editor do Supabase, no
  Power BI, numa consulta SQL avulsa. O nome entra **apenas nas views**: as
  tabelas base seguem normalizadas, sem coluna de nome duplicada. Duplicar ali
  seria o mesmo erro que a seção 6 já eliminou ao remover as colunas calculadas
  da planilha antiga — dado derivado que vira coluna é dado que desatualiza no
  dia em que a categoria for renomeada.

- **`v_recorrentes_ciclo`** gera a **sequência de ciclos** diretamente
  (`generate_series` sobre o próprio ciclo de início até o horizonte
  configurado) — não uma data de calendário por mês que depois vira ciclo.
  `dia_referencia` é só metadado informativo, não entra no cálculo de a
  qual ciclo cada ocorrência pertence.

> **Nota histórica (bug de produção, não reintroduzir):** a primeira versão
> gerava uma data de calendário por mês a partir de `dia_referencia`
> (clampada ao fim do mês) e só depois calculava o ciclo dessa data via
> `ciclo_caixa()`. Isso parecia correto e passou despercebido até o app ser
> usado com dados reais: para um recorrente com `dia_referencia` perto do
> dia de recebimento (ex.: salário, dia 29), o "dia 29 fixo" às vezes cai
> antes do limiar de `data_recebimento()` daquele mês e às vezes depois --
> porque esse limiar se desloca ±2 dias por causa do ajuste de fim de
> semana (seção 4), não porque o dia do salário mudou. O resultado: o
> salário duplicava em alguns ciclos e sumia por completo em outros,
> produzindo uma "Previsão do horizonte" que alternava entre valores muito
> altos e muito baixos, mês sim, mês não. Corrigido gerando a sequência de
> ciclos diretamente, que é sempre consecutiva e não tem essa ambiguidade.
- **`v_fluxo`** trata parcelamentos e avulsos como sempre `'pago'`: ao
  contrário dos recorrentes, eles não passam por confirmação por ciclo — são
  lançados quando o fato já ocorreu (a compra foi feita, o parcelamento foi
  contratado). O sufixo de exibição `"(n/total)"` da descrição das parcelas é
  aplicado só aqui, na união, para manter `v_parcelas` fiel ao SQL literal da
  especificação.
- **`v_previsao`** ancora a projeção na linha mais recente de `saldos` por
  usuário. Sem nenhuma conciliação registrada não há ponto de partida — o
  usuário simplesmente não aparece na view até registrar o primeiro saldo
  apurado em Configuração. `valor_apurado` representa o saldo real **no
  início do ciclo** ao qual está associado (mesmo conceito de "SALDO NO
  PRIMEIRO DIA DO MÊS (DIA DE RECEBIMENTO)" que já existia na aba Dashboard
  da planilha antiga) -- a projeção soma o saldo previsto de cada ciclo
  futuro em cima desse ponto de partida, começando do ciclo seguinte ao
  registrado. Na pratica, para o primeiro cadastro, usar o saldo real do dia
  já é uma aproximação razoável; ela só fica exata a partir do próximo ciclo,
  quando a conciliação for atualizada de novo logo apos o salário cair.

  > **Correção (nov/2026): saldo apurado de hoje, em qualquer dia.** O texto
  > acima dizia "início do ciclo", mas a fórmula tratava `valor_apurado` como
  > o saldo do **fim** do ciclo (os lançamentos do próprio ciclo da âncora não
  > eram somados), o que só batia se o usuário registrasse no dia exato. Agora
  > `saldos.data_apuracao` guarda o dia da leitura e a view `v_ancora_saldo`
  > calcula `saldo_fim_ciclo = valor_apurado + pendente`, onde *pendente* é o
  > que, naquele dia, ainda não passou pela conta no ciclo. A régua é a nova
  > coluna `v_fluxo.data_caixa`, o dia em que o dinheiro de fato se move:
  > crédito → vencimento da fatura; avulso → data do lançamento; folha →
  > início do ciclo; parcela fora do crédito → mesmo dia do mês da compra,
  > dentro do ciclo (`dia_no_ciclo`); recorrente → data em que foi pago, ou o
  > dia previsto se não foi confirmado. Recorrente não confirmado cujo dia já
  > passou conta como já ocorrido: o saldo do banco já o reflete (a regra
  > anterior, "pendente até marcar pago", inflava a previsão com salários que
  > já tinham caído). Saldos antigos, sem data, mantêm o significado de fim de
  > ciclo. Na tela Configuração o campo virou **"Saldo de hoje"** e mostra o
  > pendente e o saldo esperado no fim do ciclo. Teste:
  > `04_saldo_apurado_de_hoje.sql`. Combina com a seção 14: o saldo de
  > `GET /accounts` da Pluggy pode alimentar essa âncora automaticamente.
- **`v_saldo_acumulado`** generaliza `v_previsao` para qualquer ciclo, não só
  os futuros dentro do horizonte: útil para o Resumo, que deixa navegar para
  meses passados e quer mostrar "quanto eu teria acumulado até aqui", não só
  o saldo isolado daquele mês. A fórmula usa uma única soma-prefixo (`sum(saldo)
  over (order by ciclo)`, sempre crescente) e subtrai o prefixo no ciclo-âncora
  do prefixo no ciclo-alvo -- funciona para ciclos antes ou depois da âncora
  sem precisar de dois ramos de cálculo com sinal invertido.
- **Juros de cheque especial na projeção (nov/2026).** Saldo acumulado negativo
  no fim de um ciclo é cheque especial, e o banco cobra juros sobre ele no ciclo
  seguinte. `v_saldo_acumulado` passa a cobrar isso nos ciclos **futuros**:
  `juros(C) = taxa × max(0, −acumulado(C−1))` e
  `acumulado(C) = acumulado(C−1) + saldo(C) − juros(C)`. Juros sobre juros saem
  sozinhos enquanto o saldo seguir negativo.
  - **Só depois do corte** `max(ciclo da âncora, ciclo atual)`: o passado é
    realizado, e o juro cobrado de verdade entra como lançamento real (e, com a
    seção 14, chega sozinho do banco). O ponto de partida é o saldo apurado
    informado pelo usuário: se ele for negativo, o ciclo seguinte já cobra juros.
  - **Taxa em `config.taxa_cheque_especial`** (fração; padrão `0.08965` =
    8,965% a.m., juros de 8% + IOF), editável em Configuração como %. Taxa
    única é aproximação levemente pessimista: o IOF fixo de 0,38% incide só
    sobre o valor que *entrou* no negativo, não sobre o saldo inteiro todo mês.
  - **Limite conhecido:** olha só o saldo no **fim** do ciclo. Negativo apenas
    no meio do mês (antes do salário) gera juros reais que a projeção não vê.
  - Como cada ciclo passa a depender do anterior, a soma-prefixo vira recursão
    nos ciclos futuros (os anteriores continuam pela soma-prefixo, com o mesmo
    valor de antes, conferido ciclo a ciclo). **`v_previsao` passa a ler de
    `v_saldo_acumulado`**: uma regra só, e os dois números nunca divergem.
  - O Resumo mostra os juros previstos do mês e, na Previsão do horizonte,
    quanto de cada saldo é juro. Teste pgTAP: `03_cheque_especial.sql`.
- **`v_reserva_estimados`** responde a uma pergunta que surgiu em uso real:
  quando um item `estimado` (combustível, manutenção) custa menos que o
  provisionado num mês, essa diferença "some" ou fica guardada em algum
  lugar? A view acumula previsto − realizado por item, somando só os ciclos
  com `execucoes.status = 'pago'` (ciclos ainda não confirmados não contam --
  a reserva só reflete o que o usuário efetivamente registrou). Gastar menos
  que o provisionado aumenta a reserva; gastar mais a consome.

---

## 8. Segurança — requisitos de implementação

- `alter table X enable row level security` em **todas** as tabelas.
- Policy padrão por tabela: `using (user_id = auth.uid())` e
  `with check (user_id = auth.uid())`, para select, insert, update e delete.
- `user_id` preenchido por `default auth.uid()`, nunca pelo cliente.
- Views devem respeitar o RLS das tabelas base (`security_invoker = true`).
- MFA (TOTP) habilitado no Supabase Auth.
- **Teste obrigatório antes de inserir dado real:** tentar ler as tabelas com a
  chave `anon` sem sessão autenticada. O resultado deve ser vazio. Se retornar
  qualquer linha, o RLS está incorreto e o projeto não avança.

> **Descoberta na implementação:** RLS sozinho não basta. Por padrão, o
> Supabase não expõe mais tabelas, views e funções novas às roles da API
> (`anon`, `authenticated`) sem `GRANT` explícito — sem os `GRANT`s, o teste
> acima daria "vazio" pelo motivo errado (permissão negada, não RLS), e pior:
> as views quebrariam para todo usuário autenticado, porque as funções de
> calendário são chamadas de dentro de views `security_invoker`, e o Postgres
> cobra `EXECUTE` de quem está consultando, não de quem criou a view. A v1
> concede `SELECT` em todas as tabelas para `anon` e `authenticated` (mais
> `INSERT/UPDATE/DELETE` só para `authenticated`), `SELECT` nas views para
> `authenticated`, e `EXECUTE` nas 5 funções de calendário para `authenticated`.

---

## 9. Escopo do front-end (v1)

PWA instalável na tela inicial. Prioridade absoluta: **velocidade de lançamento**.

1. **Login** — e-mail e senha, com MFA. Sessão persistente.
2. **Lançamento rápido** — tela inicial. Valor, descrição, categoria, meio de
   pagamento, data (padrão: hoje). Meta: menos de 15 segundos por lançamento.
3. **Novo parcelamento** — descrição, categoria, meio, data da compra, valor da
   parcela, quantidade. Mostra a projeção antes de salvar.
4. **Ciclo atual** — lista de recorrentes do ciclo com alternância pendente/pago
   e campo para valor realizado, em qualquer recorrente (não só nos itens
   `estimado` -- ver nota histórica abaixo).
5. **Extrato** — navega mês a mês (atual e passado) por todas as transações
   do ciclo (`v_fluxo`). Dois modos: detalhado (edita valor de avulsos e
   recorrentes, edita a data e exclui avulsos, e mostra data · vencimento da
   fatura · categoria · meio de pagamento · origem em cada linha) e resumido
   (descrição, meio de pagamento, valor e status, sem controles, pensado pra
   consulta rápida tipo extrato bancário). Parcelas de parcelamento aparecem
   só leitura em ambos os modos -- o valor é da série inteira, não há coluna
   para sobrescrever uma parcela isolada.
6. **Resumo** — navega mês a mês como o Extrato. O card do ciclo (receitas,
   despesas, saldo do próprio mês, saldo acumulado até ali) e o ranking de
   gastos por categoria mudam com a navegação; o painel de alertas, previsão
   do horizonte e reservas dos itens estimados fica fixo, por ser uma projeção
   a partir do histórico inteiro, não do mês em exibição.
7. **Configuração** — parâmetros do ciclo, categorias, descontos em folha,
   saldo apurado (conciliação usada pela previsão do horizonte).

As telas Ciclo, Extrato e Resumo mostram, abaixo do título, o **intervalo de
datas do ciclo** em exibição (ex.: "28/08/2026 a 28/09/2026"), vindo de
`ciclo_inicio`/`ciclo_fim` (seção 5). Sem isso, o rótulo "setembro de 2026"
sozinho é ambíguo -- o mês financeiro não coincide com o mês do calendário, e
essa é justamente a regra que mais confunde na hora de conferir um lançamento.

> **Nota (dúvida recorrente em uso real — não é bug):** o intervalo do ciclo
> NÃO é o intervalo das compras que aparecem nele. Uma compra no crédito entra
> no ciclo em que a **fatura vence**, não no da compra (seção 4): no ciclo de
> setembro (28/08 a 28/09) aparecem as compras no crédito de ~28/07 a 27/08
> (fatura que vence 03/09), e as feitas no crédito entre 28/08 e 27/09 só
> aparecem em outubro. Isso pareceu um erro ao usuário ("setembro mostra
> compras de julho"). Decisão: manter a regra — é ela que faz saldo e
> previsão baterem com o dinheiro real na conta — e torná-la visível: cada
> linha no crédito do Extrato detalhado mostra "fatura vence dd/mm/aaaa"
> (`v_fluxo.fatura_vencimento`, via `fatura_vencimento_no_ciclo`). Uma visão
> alternativa "por data da compra" foi oferecida e recusada por ora.
>
> Editar a data de um avulso pode mudá-lo de ciclo; o banco recalcula
> (`ciclo_caixa`) e o app avisa para qual ciclo a compra foi. Parcelas e
> recorrentes não têm data editável: a data da parcela é a da série inteira, e
> o ciclo do recorrente não depende de data.

Fora do escopo da v1: gráficos elaborados (é papel do Power BI), múltiplos
usuários, anexos, integração bancária. Também fora do v1: editar o
*cadastro* de um recorrente ou parcelamento (valor previsto, dia de
referência, categoria, meio de pagamento) -- isso ainda é via Table Editor
do Supabase Studio. Editar o *valor realizado de um ciclo específico* de um
recorrente, isso o app já cobre (Ciclo atual e Extrato); e excluir um avulso
específico também (Extrato).

> **Atualização:** a integração bancária, citada acima como fora do escopo da v1,
> passou a ser a v2 -- ver seção 14.

> **Nota histórica (evolução em uso real):** as telas Ciclo atual e Extrato
> não nasceram assim. Ciclo atual só deixava editar o valor realizado dos
> itens `estimado`, e não existia nenhuma forma de olhar meses passados ou
> excluir um avulso lançado errado -- os dois foram pedidos de uso real,
> depois de rodar o app no dia a dia com dados de verdade. Extrato reaproveita
> o mesmo padrão de navegação por mês (setas ‹ ›) que depois também foi
> aplicado ao Resumo.

> **Nota histórica (lacuna encontrada em uso real):** a lista original desta
> seção não previa nenhuma tela para a tabela `saldos` -- só ao usar o app de
> verdade ficou claro que a tela Resumo já instruía "registre um saldo
> apurado em Configuração para começar a projetar" sem que essa ação
> existisse em lugar nenhum. Corrigido acrescentando a seção "Saldo apurado"
> em Configuração (item 6 acima).

> **Nota histórica (bugs de implementação — não reintroduzir):** o fluxo de
> MFA só existe porque o app foi testado de ponta a ponta num navegador de
> verdade (enroll real + código TOTP válido gerado a partir do segredo +
> desafio no login), não só por inspeção de código — e depois testado de novo
> contra o projeto Supabase Cloud real, o que revelou um terceiro bug que o
> ambiente local não expôs. Três bugs reais só apareceram assim:
>
> 1. **O formulário de desafio de MFA ficava visível na tela de login antes
>    da hora.** Causa: a regra `.form { display: flex }` do CSS do app tem a
>    mesma especificidade do `[hidden]` padrão do navegador, e CSS de autor
>    vence CSS de agente de usuário em empate de especificidade — então
>    `hidden` parava de esconder qualquer elemento com `class="form"`.
>    Corrigido com `[hidden] { display: none !important; }` explícito no
>    stylesheet.
> 2. **O QR code do enrolamento de MFA aparecia como texto bruto**
>    (`data:image/svg+xml;utf-8,...`) em vez de imagem. Causa:
>    `supabase.auth.mfa.enroll()` devolve `totp.qr_code` já como **data URI
>    completa**, não como marcação SVG crua — inserir isso via `innerHTML`
>    faz o navegador tratar o prefixo da URI como texto solto antes da tag
>    `<svg>`. Corrigido usando `<img src="{qr_code}">` em vez de injetar o
>    valor direto no HTML.
> 3. **Contra o projeto Supabase Cloud (não contra o local), o `<img
>    src="{qr_code}">` do item 2 quebrava de novo** — ícone de imagem
>    quebrada e o final do template (`" alt="QR code do autenticador">`)
>    vazando como texto na tela. Causa: a versão do GoTrue em produção
>    aparentemente gera o data URI do SVG com aspas literais não
>    escapadas, que fecham o atributo `src="..."` no meio da string quando
>    ela é interpolada como texto de HTML — um problema de version skew
>    entre o Auth local e o cloud que não aparece testando só localmente.
>    Corrigido atribuindo `img.src = qr_code` via propriedade do DOM em vez
>    de interpolar no template — isso nunca precisa de escape, então é
>    seguro para qualquer formato que o Auth devolva. Também foi
>    acrescentado um campo com a chave TOTP em texto, para digitação manual
>    quando a câmera não conseguir ler o QR.

---

## 10. Ordem de implementação sugerida

1. Projeto Supabase + schema + funções de calendário.
2. **Testes das funções de calendário** contra casos conhecidos, incluindo a
   janela crítica dias 27–30 e meses em que o penúltimo dia cai em fim de semana.
3. RLS + teste de vazamento (seção 8).
4. Views de cálculo.
5. Front-end PWA.
6. Deploy no GitHub Pages + Action anti-pausa (cron diário).
7. Conexão do Power BI Desktop.
8. Migração dos dados históricos.

Os passos 2 e 3 são portões: não avançar sem eles verdes.

> **Atualização (v2):** a integração Open Finance (seção 14) é executada **antes**
> do passo 7 (Power BI). Os passos 1–6 e 8 estão concluídos (seção 13).

---

## 11. Migração

Origem: planilha com as abas `Lançamentos`, `Lançamentos Diversos`,
`Parcelamentos`, `Receitas_Fixas`, `Despesas_Fixas`, `Categorias`, `Previsao`.

- O formato de origem **não deve ser preservado**. Normalizar para o modelo acima.
- `Previsao` não é migrada (é resultado, será recalculada).
- `meio_pagamento` não existe nos dados antigos: inferir do histórico onde
  possível (descrições contendo "Pix", "Fatura", "Parcelamento") e listar os
  casos ambíguos para decisão manual.
- Parcelamentos finalizados são migrados como histórico, não descartados.
- Exportar cada aba em CSV; script de importação idempotente e reexecutável.

### Registro da migração (concluída)

> Scripts em `migracao/` (fora do git -- repo público, planilha tem
> descrições pessoais). `transformar.mjs` le o `.xlsm` e gera CSVs
> normalizados em `migracao/saida/`, sem tocar no banco; `importar.mjs`
> autentica como o próprio usuário (nunca `service_role`) e grava, checando
> o que já existe antes de cada inserção.

Decisões e descobertas que só apareceram ao migrar os dados de verdade:

- **Formato numérico da planilha é dos EUA, não brasileiro:** vírgula separa
  milhar e ponto é decimal (`R$3,765.60`), o oposto do que se assumiria à
  primeira vista. Um parser inicial que assumia formato brasileiro cortava
  valores acima de mil (ex.: `3765.60` virava `3.765`).
- **4 categorias antigas misturavam despesa e receita**
  (`Salário Folha Normal`, `Faturas Gerais`, `Empréstimo Bancos`,
  `Transporte`) -- o schema novo exige um tipo único por categoria. Resolvido
  mantendo o nome no tipo majoritário e roteando o tipo minoritário para
  categorias genéricas `Outras receitas` / `Outras despesas`.
- **Meio de pagamento não é o mesmo palpite para despesa e receita.** Um
  fallback único de "crédito" para todo lançamento ambíguo produz absurdos
  como salário "recebido no crédito". A regra final: despesa ambígua ->
  crédito; receita ambígua -> pix (crédito não existe como meio de entrada
  de dinheiro).
- **Todo item fixo (salário, assinaturas, contas) também estava logado
  individualmente, mês a mês, em `Lançamentos`** -- é assim que a planilha
  antiga rastreava recorrência, sem o conceito de `execuções` do schema
  novo. Migrar o cadastro fixo (`recorrentes`) E essas ocorrências mensais
  (`avulsos`) teria duplicado todo mês histórico. Resolvido reconstituindo
  cada ocorrência como uma linha em `execucoes`, com o ciclo calculado pela
  própria função `ciclo_caixa` do banco via RPC -- nunca reimplementado em
  JavaScript, para não abrir uma segunda fonte de verdade para a regra de
  competência.
- **`Contribuição INSS` e `Seguro de vida coorporativo` estavam
  categorizados como despesa recorrente da categoria "Salário Folha
  Normal"** -- exatamente o problema que a seção 6 já documentava. Migrados
  para `descontos_folha` (INSS como 8,45% percentual, seguro como valor
  fixo); as ocorrências históricas desses dois na antiga `Lançamentos` foram
  descartadas, já que `descontos_folha` é uma regra, não um lançamento.
- **Bug de importação:** `fatura_fecha`/`fatura_vence` leem a linha de
  `config` do usuário sem filtro explícito (a própria RLS resolve). Sem uma
  linha em `config`, `ciclo_caixa` para qualquer lançamento no crédito
  retorna `null` silenciosamente (zero linhas casadas com `where`, não um
  erro), quebrando a inserção de `execucoes` com violação de not-null. O
  script de importação agora cria a `config` padrão (27/3/3) automaticamente
  se ainda não existir, antes de qualquer outra coisa.
- Dois casos ficaram de fora por decisão consciente, para revisão manual
  futura direto no app: um parcelamento sem nenhuma parcela correspondente
  em `Lançamentos`, e uma compra parcelada que nunca foi cadastrada na aba
  `Parcelamentos` (migrada como avulsos soltos em vez de parcelamento).

#### Remigração v2 (planilha corrigida com meio de pagamento explícito)

Poucos dias depois da primeira migração, o usuário notou lançamentos
aparecendo no ciclo errado e refez a planilha original acrescentando duas
colunas que não existiam: tipo (despesa/receita, já existia parcialmente) e
**meio de pagamento** (pix/crédito/débito/dinheiro/boleto/folha) em cada
linha de `Lançamentos`/`Lançamentos Diversos`. Isso eliminou de vez a
inferência por palavra-chave da v1 -- na prática, 0 avulsos e 0 parcelamentos
precisaram de um valor chutado desta vez (só 1 recorrente inativo, nunca
usado, sem nenhuma ocorrência histórica para consultar).

- **Parcelamentos e recorrentes ganharam meio de pagamento por voto
  majoritário**, não mais por palpite de palavra-chave: como essas duas
  tabelas não têm coluna própria de meio, o script busca as ocorrências reais
  já casadas em `Lançamentos` (mesma lógica de reconciliação da v1) e usa o
  meio mais frequente entre elas. Isso corrigiu palpites da v1 que estavam
  errados -- ex.: "Financiamento Uno" e sua entrada, que a v1 chutou como
  `debito` (parecia um financiamento bancário), na real são pagos por `pix`.
  *(Correção em out/2026, ver 14.15: o usuário informa que financiamentos e
  empréstimos são sempre pagos por débito direto automático.)*
- **Nem todo item chamado "Pix" no nome é pago em pix de verdade.** Dois
  parcelamentos com "Pix" na própria descrição (`Carona BJ-CG-BJ - Pix
  parcelado`, `Pix Rifa Casamento...`) tiveram `Crédito` como meio
  majoritário nas ocorrências reais marcadas pelo usuário. O dado real
  (preenchido com cuidado, linha a linha) prevalece sobre qualquer suposição
  a partir do texto da descrição.
- **"Folha de salário normal" votou `pix`, não `folha`** -- a planilha não
  tinha como o usuário marcar "Folha" nas linhas individuais, só as opções de
  meio de verdade. Como `folha` e `pix` se comportam identicamente em
  `ciclo_caixa` (a distinção é só categorização, sem efeito em nenhum
  cálculo), o script força `folha` só para o recorrente de salário, por ser
  semanticamente mais correto, sem alterar nenhuma previsão.
- **`importar.mjs` ganhou um modo `--wipe`**, pedindo a palavra `APAGAR`
  digitada como confirmação: apaga `execucoes`, `avulsos`, `parcelamentos`,
  `recorrentes`, `descontos_folha` e `categorias` do usuário autenticado, sem
  tocar em `config`, `saldos` ou na conta/login/MFA -- necessário para
  remigrar do zero sem deixar dado antigo e novo misturado.
- **Bug encontrado no próprio `--wipe`:** a interface de `readline` do
  terminal era fechada logo depois da senha, antes da pergunta de
  confirmação `APAGAR` -- que também precisa dela. Resultado: `readline was
  closed` e o processo Node caía com um assert interno do libuv. Corrigido
  fechando a interface só depois da última pergunta possível em cada um dos
  dois caminhos (`--wipe` e importação normal), nunca antes.

---

## 12. Fase 2 (não implementar agora)

- Criptografia client-side do campo `descricao`.
- Calibração automática dos valores estimados a partir do histórico.
- Metas de gasto por categoria.

---

## 13. Registro de implementação (v1)

> Acrescentado após a primeira rodada de implementação. Mesmo espírito da
> nota histórica da seção 4: isto é histórico — não apagar ao evoluir o
> projeto, só acrescentar.

### Ambiente e stack (decisões tomadas, não estavam fechadas na v1 original)

- **Banco, dev/teste:** Supabase CLI local + Docker Desktop (WSL2). Permite
  rodar `supabase start` e `supabase test db` sem depender de conta cloud
  durante o desenvolvimento; a conta Supabase Cloud só entra no deploy
  (fase 6).
- **Front-end:** Vite + TypeScript + vanilla, sem framework, com
  `vite-plugin-pwa` para manifest e service worker. Router próprio por hash
  (`app/src/router.ts`), sem biblioteca de roteamento externa.

### Portões da seção 10 — status

- **Calendário:** 23 testes pgTAP verdes
  (`supabase/tests/database/01_calendario.sql`), cobrindo os 12 meses de
  2026, fevereiro bissexto de 2028, e os três casos de validação da seção 4
  (crédito 10/set, pix 10/set, crédito 28/set).
- **RLS:** 13 testes pgTAP verdes (`02_rls_leak.sql`) mais a verificação
  manual, seguindo a letra da seção 8: chave `anon` real, sem sessão, contra
  a API REST de verdade — zero linhas em todas as tabelas.

### Status das fases da seção 10

Fases 0–6 e 8 completas. Fase 7 (Power BI) é a única que falta.

- **Fase 6 (deploy):** projeto Supabase Cloud criado (`Finances-DB`, região
  `sa-east-1`), `supabase link` + `supabase db push` feitos, RLS verificado
  também no cloud (zero linhas via `anon` real). Front-end publicado no
  GitHub Pages (`.github/workflows/deploy.yml`) com Action de anti-pausa
  diária (`keepalive.yml`). MFA cadastrado e testado na conta real, incluindo
  dois bugs só visíveis contra o Cloud (ver nota histórica da seção 9).
- **Fase 8 (migração):** dados históricos da planilha `Controle de Despesas`
  migrados por completo -- ver seção 11 para as decisões e descobertas.
- **Fase 7 (Power BI):** não iniciada; passa a vir **depois** da integração
  Open Finance (seção 14).

### Iterações pós-lançamento (uso real, ainda dentro da v1)

Depois que o app foi ao ar com dados reais, uma rodada de melhorias pedidas
em uso genuíno: tela Extrato (ver seção 9), navegação por mês também no
Resumo, `v_saldo_acumulado` e `v_reserva_estimados` (ver seção 7), e liberar
a edição de valor realizado para qualquer recorrente no Ciclo atual, não só
os `estimado`. Isso reforça o porquê da seção 10 ordenar "front-end" antes
de "deploy" mas depois de tudo que é motor de cálculo: boa parte do que
realmente falta descobrir num app de finanças pessoal só aparece usando ele
de verdade, com dinheiro de verdade, mês após mês -- não dá pra prever tudo
sentado na especificação.

---

## 14. Integração Open Finance (Pluggy) — v2

> Acrescentada após o uso real da v1. **Esta etapa vem antes da Fase 7 (Power BI)
> da seção 10.** Mesmo espírito das seções 11 e 13: o que já está escrito não se
> apaga, só se acrescenta.
>
> Marcações usadas nesta seção:
> **[decidido]** decisão do usuário · **[verificado]** confirmado na documentação
> da Pluggy (consultada em outubro/2026) · **[a validar]** hipótese de projeto
> que depende do teste de reconhecimento (14.13, Fase A) ou de uso real.

### 14.1 Objetivo e motivação

O problema real da v1 não é de cálculo, é de digitação. Esquecer ou não ter tempo
de lançar cria buracos no extrato, e buraco no extrato destrói a previsibilidade,
que é a razão de existir do sistema **[decidido]**.

A v2 troca **digitar** por **revisar**: as transações chegam sozinhas dos bancos
via Open Finance e o usuário só decide o que for ambíguo. O princípio central
(14.5) é que a previsão **não pode depender** de o usuário revisar: o que é seguro
de contar entra no saldo na hora; o que é ambíguo espera confirmação, mas fica
visível.

Escopo: somente leitura (contas, cartões, transações, faturas). Fora do escopo:
iniciar pagamentos, investimentos, identidade.

### 14.2 Premissas e restrições

**Caminho de acesso [decidido] [verificado].** API da Pluggy por meio do
**Meu Pluggy**: os bancos são autorizados em `meu.pluggy.ai`, e uma aplicação no
Dashboard (mesma conta) conecta o conector **MeuPluggy (id 200)** como proxy.
**Não criar conexões diretas pelo Dashboard**: depois do trial de 15 dias elas
pausam, e vários conectores diretos de pessoa física estão sendo descontinuados.
O trial não afeta o MeuPluggy. A integração direta pela API é o caminho
preferido; extrair dados das telas do Meu Pluggy/Dashboard só seria plano B se a
API se mostrasse inviável (frágil, e exigiria guardar login).

**Limites do uso pessoal [verificado].** Até 5 conexões ativas, mesmo titular,
uso não comercial. Uma autorização por banco no conector (banco adicionado
depois exige nova autorização). Atualização automática a cada 24 h, gratuita,
**sem como forçar** (o item proxy não aceita atualização manual). Consequência
de projeto: não existe tempo real; defasagem de até cerca de um dia é normal.

**Limites do Open Finance por CPF, por instituição, por mês [verificado].**
Transações históricas (de 7 dias a 12 meses): **4 chamadas**; recentes: 240;
listagem de contas: 30. O histórico disponível é de até **12 meses**. Regra
dura: **nunca apagar e recriar itens/conexões para testar** — isso gasta a cota
histórica por até um mês. Todo ambiente (inclusive o projeto-cópia, 14.3) lê do
**mesmo item** MeuPluggy.

**API.** Usar `GET /v2/transactions` (paginação por cursor, `ids` com no máximo
500 por chamada). Contas criadas a partir de junho/2026 já usam o v2 por padrão e
o v1 será descontinuado para elas em dezembro/2026 **[verificado]**.

**R1 (custo zero).** MeuPluggy é gratuito; Edge Functions e GitHub Actions ficam
dentro dos planos gratuitos; nenhum serviço novo recebe cartão cadastrado.

**R2/R3 (segurança).**

- `CLIENT_ID`/`CLIENT_SECRET` da Pluggy e o CPF do titular existem **somente**
  como secrets do Supabase (Edge Functions). Nunca no repositório, no front-end,
  em `.env` versionado, em log, em prompt ou neste documento.
- **Lista fixa de campos (whitelist).** A função grava apenas: data, valor,
  sentido, descrição, tipo de operação, tipo de conta, status Pluggy, ids
  técnicos (`pluggy_id`, `provider_id`, `bill_id`, `conta_pluggy_id`) e dados de
  parcela. **Descarta** CPF/CNPJ, agência, número de conta e o restante do
  `paymentData`. O destinatário de um Pix é reduzido a um booleano
  (`transferencia_propria`) calculado dentro da função.
- Os ids técnicos da Pluggy e o `provider_id` não são "identificador bancário"
  no sentido de R3 (não dão acesso a nada); são permitidos.
- Descrições de Pix trazem **nomes de terceiros**. Não é dado que cause fraude,
  mas é privacidade. A criptografia client-side de `descricao` (seção 12) ganha
  relevância e deve ser reavaliada assim que a integração estiver em uso.
- O servidor MCP da Pluggy conectado ao Claude serve só para **documentação**.
  As ferramentas de escrita dele não injetam credencial, e **nenhum segredo é
  colado em chat**. Testes com credenciais rodam localmente no Claude Code.

### 14.3 Ambiente: projeto-cópia

- **Projeto Supabase novo, cópia do atual [decidido].** O projeto atual
  (`Finances-DB`) permanece **intacto** e é a referência. O novo ocupa o 2º e
  último projeto do plano gratuito e precisa do próprio keepalive.
- Criação: `supabase link` no projeto novo + `supabase db push` das mesmas
  migrations (nunca copiar tabelas à mão), depois as migrations da v2. Os 36
  testes pgTAP existentes continuam sendo portões.
- **"Limpar o banco e importar pela API" [decidido] significa limpar
  *movimentos*, mantendo *cadastros*.** Remove `avulsos` e `execucoes`. Mantém
  `config`, `categorias`, `recorrentes`, `parcelamentos`, `descontos_folha` e
  `saldos`, que são regras e projeção futura que a Pluggy não fornece.
- O `--wipe` atual do `importar.mjs` apaga cadastros: **não usar** aqui. Criar
  `--wipe-movimentos`, com a mesma confirmação digitada (`APAGAR`).
- Consequência assumida: o histórico anterior à janela de ~12 meses da API só
  existe no projeto atual. Ver pendência sobre ciclos antigos em 14.15.
- Destino do projeto-cópia depois de validado (virar produção ou ser
  descartado): **em aberto** (14.15).

### 14.4 Fluxo ponta a ponta

```
meu.pluggy.ai     consentimento Open Finance (autorização por banco) + sync a cada 24 h
   ↓ conector MeuPluggy (id 200), item "proxy"
API da Pluggy ── webhooks transactions/created|updated|deleted ──▶ Edge Function pluggy-webhook
   ▲                                                                   │ valida cabeçalho secreto,
   │                                                                   │ responde 2xx rápido
   └── GET /v2/transactions · /bills · /items (apiKey por CLIENT_ID/SECRET) ◀┘
                                                                       ↓ whitelist de campos (R3)
                         transacoes_bancarias (staging, RLS) ──▶ casar_transacoes_bancarias()  [SQL]
                                                                       ↓
        vinculada (recorrente · parcela · liquidação) │ provisória (crédito/débito) │ para_revisar
                                                                       ↓
                       v_fluxo (cada transação conta exatamente uma vez) ──▶ App · Power BI

GitHub Actions (cron) ──▶ Edge Function pluggy-sync
                          conferência diária (14 dias) + semanal (90 dias) + saúde das conexões
```

### 14.5 Regras de contagem (princípio central)

A aba do app chama-se **"Para revisar" [decidido]**. Não usar "Pendente": a
Pluggy já usa `PENDING` com outro sentido (fatura aberta) e o schema já tem
`pendente` em `status_execucao`. Três "pendentes" diferentes confundem.

Regra do usuário **[decidido]**: só **crédito, débito e parcelamentos** entram no
cálculo, no resumo e na previsão **antes** de confirmados. Pix, transferências e
as demais só contam **depois** de confirmados (podem ser transferências entre
contas do próprio usuário, que não são gasto).

| Origem na Pluggy | Estado inicial | Entra no saldo/previsão? |
|---|---|---|
| Compra no cartão de crédito (`tipo_conta = CREDIT`, saída, `tipo_operacao = PAGAMENTO`) | `para_revisar` (ou `vinculada`, se casar) | **Sim, provisório**, com o ciclo da regra do crédito (`ciclo_caixa`) |
| Compra no débito (`tipo_conta = BANK`, `tipo_operacao = CARTAO`) **[a validar]** | `para_revisar` | **Sim, provisório** |
| Parcela de parcelamento cadastrado | `vinculada` à série | Sim, por `v_parcelas` (não pela staging) |
| Recorrente casado (salário, assinatura, conta, financiamento/empréstimo em débito automático) | `vinculada` à execução (`pago`) | Sim, pela execução |
| Pagamento de fatura (lado cartão `PAGAMENTO_FATURA`; lado conta casado com ele) | `vinculada` como liquidação | **Não**: liquida compras já contadas |
| Pix, TED, DOC, boleto, depósito e demais, de entrada ou saída | `para_revisar` | **Não**, só após confirmar |
| Tipos do cartão fora de compra (estorno, cashback, tarifa, operação de crédito contratada) | `para_revisar` | **Não**, só após confirmar |
| Transferência própria (`transferencia_propria = true`) | `para_revisar`, sugestão "ignorar" | Não |
| Transação removida pela Pluggy | `removida` | Não |

**Invariante da contagem única.** Cada transação do banco contribui para saldo e
previsão **no máximo uma vez, por exatamente um caminho**:

1. provisória (`estado = 'para_revisar'` e elegível pela tabela acima), **ou**
2. pelo cadastro a que foi vinculada (execução, parcela), **ou**
3. pelo `avulso` criado na confirmação.

Nunca por dois ao mesmo tempo. Este é o **Portão 3** (14.12) e mora em teste
pgTAP **[decidido]**.

**Ciclo de vida de um item:**

- **Confirmar:** vira um `avulsos` (categoria, meio e tipo escolhidos ou
  sugeridos, `transacao_banco_id` preenchido, valor do banco) e a linha da
  staging passa a `confirmada`. A contagem **muda de caminho** (de provisória
  para o avulso), sem somar duas vezes.
- **Ignorar:** `ignorada`. Fica guardada para não ser reimportada e para poder
  ser desfeita.
- **Vincular a algo existente:** `vinculada`, com o vínculo registrado.
- **Desfazer:** volta a `para_revisar` e desfaz o avulso/vínculo criado.
- **Removida pelo banco:** se estava `vinculada` ou `confirmada`, o app sinaliza
  "o banco removeu esta transação" para decisão do usuário (nada se desfaz
  sozinho). Se voltar com a mesma `chave_dedupe`, é restaurada.

**Depois de confirmadas ou ignoradas, as transações saem da aba "Para
revisar" [decidido]**: a lista mostra só o que precisa de decisão. Existe uma
visão secundária "Revisadas" (confirmadas e ignoradas) com **desfazer**, para
corrigir um toque errado.

### 14.6 Motor de casamento

Função SQL idempotente `casar_transacoes_bancarias()`: a regra mora no banco,
como `ciclo_caixa` (R4), **nunca em JavaScript**. Roda após cada ingestão e sob
demanda (RPC). **Precedência: a primeira regra que casar vence.**

1. **Liquidação de fatura.** Lado cartão: `tipo_operacao = 'PAGAMENTO_FATURA'`.
   Lado conta: débito cujo valor e data (±3 dias) batem com um pagamento de
   fatura. → `vinculada`/`liquidacao`; não conta. Um débito de conta que *parece*
   pagamento de fatura mas **não casou** NÃO entra como provisório: fica
   `para_revisar` fora do saldo (evita contar a fatura duas vezes).
2. **Parcela cadastrada.** Transação de crédito com `parcela_numero` e
   `parcela_total` casa com `parcelamentos` por `valor_parcela` igual ao centavo,
   `num_parcelas = parcela_total` e (`data_compra_original ≈ data_compra`
   quando existir, ou semelhança de descrição). → `vinculada`/`parcelamento`.
3. **Recorrente.** Combina ciclo esperado, janela de dias em torno de
   `dia_referencia`, valor (exato para não estimados, faixa para `estimado`) e
   semelhança da descrição normalizada. → grava ou atualiza `execucoes` do
   ciclo: `status = 'pago'`, `valor_realizado` = valor do banco, `data_efetiva`
   = data do banco. Cobre salário, assinaturas, contas e financiamentos e
   empréstimos em débito automático (parcelas de valor e dia fixos são o caso
   mais fácil de casar). Isso elimina o Pago/Pendente manual do Ciclo atual.
4. **Lançamento manual existente.** `avulsos` ainda sem `transacao_banco_id`,
   mesmo sentido, valor igual, data ±2 dias e **candidato único** → vincula
   sozinho. Qualquer ambiguidade (mais de um candidato, valor diferente) vira
   **sugestão** na aba: "é este o seu lançamento X?". Se o valor diferir, o app
   mostra a diferença e oferece ajustar para o valor do banco (o banco é a
   verdade do realizado). A descrição do banco ("PIX ENVIADO FULANO") raramente
   se parece com a do usuário, por isso o casamento é sugestão, não certeza.
5. **Sem casamento.** Fica `para_revisar` com sugestões: categoria e meio pelas
   `regras_categoria` (padrão na descrição normalizada), meio inferido do tipo
   de conta e do `tipo_operacao`. Parcelada sem cadastro: o app oferece **criar
   parcelamento** pré-preenchido (valor da parcela, total, data da compra
   original); ao salvar, o motor **re-casa** as parcelas já importadas com a
   série nova, sem contar de novo.

**Regras aprendidas [a validar].** Cada confirmação cria ou reforça uma regra em
`regras_categoria`; depois de 2 confirmações do mesmo padrão ela passa a ser
**sugestão** pré-preenchida. Nunca confirma sozinha.

**Transferência própria.** Calculada na função de ingestão: o documento do
recebedor (`paymentData`) é comparado com `OWNER_CPF` (secret) e **só o
resultado** (`transferencia_propria`) é gravado; o documento é descartado. Pista
adicional: `tipo_operacao = TRANSFERENCIA_MESMA_INSTITUICAO` (pista, não prova:
também pode ser Pix para outra pessoa no mesmo banco). Sem `paymentData` para
aquele banco, cai no fluxo normal de "Para revisar". Tratamento: `para_revisar`
com "ignorar" a um toque, **sem ignorar automaticamente** no início — um Pix para
si mesmo pode ser aporte numa conta de investimento (existe a categoria
Investimentos) e ignorá-lo às escondidas apagaria um gasto real do planejamento.
Automatizar o ignorar só depois de semanas de uso confirmando o padrão.

### 14.7 Modelo de dados (v2)

Esqueleto. Adaptar às colunas reais de `v_fluxo` e às convenções das migrations
existentes.

```sql
create type estado_banco as enum
  ('para_revisar','vinculada','confirmada','ignorada','removida');

-- Staging das transações do banco. Escrita somente pela Edge Function / funções SQL.
transacoes_bancarias (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users,
  pluggy_id text not null,                 -- pode MUDAR (delete + recreate)
  provider_id text,                        -- id no banco; só Open Finance; chave preferida
  chave_dedupe text not null,              -- provider_id; senão hash(conta|data|valor|descricao)
  conta_pluggy_id text not null,           -- id técnico da Pluggy, NÃO é número de conta
  tipo_conta text not null check (tipo_conta in ('BANK','CREDIT')),
  data date not null,
  valor numeric(12,2) not null check (valor >= 0),
  sentido text not null check (sentido in ('entrada','saida')),
  descricao text not null,
  tipo_operacao text,                      -- PIX, TED, BOLETO, CARTAO, PAGAMENTO_FATURA...
  meio_inferido meio_pagamento,
  status_pluggy text,                      -- PENDING | POSTED
  bill_id text,
  parcela_numero smallint, parcela_total smallint,
  data_compra_original date,
  transferencia_propria boolean not null default false,
  estado estado_banco not null default 'para_revisar',
  vinculo_tipo text check (vinculo_tipo in ('execucao','parcelamento','avulso','liquidacao')),
  vinculo_id uuid,
  categoria_sugerida_id uuid references categorias,
  criada_em timestamptz not null default now(),
  atualizada_em timestamptz not null default now(),
  unique (user_id, chave_dedupe)
)

alter table avulsos add column transacao_banco_id uuid unique references transacoes_bancarias;

regras_categoria (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid(),
  padrao text not null,                    -- trecho normalizado da descrição
  categoria_id uuid not null references categorias,
  meio_pagamento meio_pagamento,
  confirmacoes int not null default 1,
  ativa boolean not null default true,
  unique (user_id, padrao)
)

conexoes_pluggy (
  user_id uuid not null, item_id text not null, apelido text,
  status text, ultima_atualizacao timestamptz,
  ultima_transacao_em timestamptz,
  consentimento_revogado_em timestamptz,
  verificada_em timestamptz,
  primary key (user_id, item_id)
)

eventos_pluggy (event_id text primary key, user_id uuid not null,
                tipo text not null, recebido_em timestamptz not null default now())

faturas_cartao (
  user_id uuid not null, bill_id text not null, conta_pluggy_id text not null,
  vencimento date not null, total numeric(12,2) not null,
  minimo numeric(12,2), permite_parcelar boolean,
  pago numeric(12,2), encargos numeric(12,2),
  primary key (user_id, bill_id)
)
```

**Chave de deduplicação.** `chave_dedupe = provider_id` quando existir (só Open
Finance **[verificado]**); senão, hash de conta + data + valor + descrição. **Não
usar o `id` da Pluggy como chave única**: se o banco para de devolver uma
transação por 1 a 3 dias, a Pluggy a apaga e a recria **com id novo**
**[verificado]**.

**Views novas** (todas `security_invoker = true`, como as demais):

| View | Responsabilidade |
|---|---|
| `v_banco_provisorio` | Linhas `para_revisar` elegíveis pela tabela de 14.5, no formato de `v_fluxo` (`origem = 'banco'`, `provisorio = true`, ciclo por `ciclo_caixa(data, meio_inferido)`) |
| `v_fluxo` (alterada) | Ganha o ramo `v_banco_provisorio` e a coluna `provisorio` (`false` nos demais). Segue sendo a única tabela-fato do Power BI |
| `v_para_revisar` | Lista da aba: sugestões, candidatos de casamento e `conta_no_saldo` (sim/não) por linha |
| `v_resumo_banco` | Contadores do Resumo: itens para revisar; valor aguardando confirmação **fora** do saldo (Pix/entradas); valor provisório **dentro** do saldo |
| `v_saude_conexoes` | Estado de cada conexão e flag `atrasada` (14.9) |
| `v_faturas_conciliacao` | Pago × devido por fatura (14.10) |

### 14.8 Ingestão: Edge Functions e agendamentos

**`pluggy-webhook`.** `verify_jwt = false` em `supabase/config.toml`, porque a
Pluggy não envia JWT do Supabase; o **cabeçalho secreto passa a ser a única
porta**.

- Primeira instrução: comparar o cabeçalho secreto em tempo constante. Falhou →
  `401` (a Pluggy não reenvia 400/401/403/404/405, o que é bom contra
  requisições forjadas).
- Responder `2xx` em até 10 s e processar depois. **Erro temporário devolve
  `5xx`, nunca `4xx`**: 4xx faz o evento ser descartado **[verificado]**.
- Deduplicar por `eventId` (`eventos_pluggy`) e por `chave_dedupe` (a Pluggy já
  reenviou as mesmas transações quando o item é atualizado várias vezes no mesmo
  dia **[verificado]**).
- `transactions/created`: seguir `createdTransactionsLink` com paginação por
  cursor. `transactions/updated`: `GET /v2/transactions?ids=…` (≤ 500) e
  atualizar (inclui `PENDING → POSTED` e o `billId`). `transactions/deleted`:
  marcar `removida` (14.5). `item/updated` e `item/error`: `GET /items/{id}`
  antes de agir e atualizar a saúde (14.9).
- Os eventos `transactions/*` não trazem `clientUserId`: o usuário é o dono único
  (`OWNER_USER_ID`).
- Cabeçalhos customizados de webhook só se configuram **via API**, não pelo
  Dashboard **[verificado]**. Registro por script único
  `integracao/registrar-webhook.mjs`, com segredos por variável de ambiente,
  nunca impressos. A documentação também cita cabeçalho de assinatura: confirmar
  o formato antes de implementar e validar a assinatura **além** do cabeçalho
  secreto, se aplicável. Filtro por IP é opcional.

**`pluggy-sync`.** Acionada por GitHub Actions (`.github/workflows/sync.yml`),
autenticada por um segredo dedicado que **só dispara a sincronização** (não lê
dados). Rotina: (a) diária — releitura dos últimos 14 dias por conta;
(b) semanal — 90 dias; (c) `GET /items` e `GET /bills`; (d) saúde das conexões.
Ela existe porque o webhook tem só 3 tentativas (imediata, ~15 min, ~2 h) e não
há reenvio depois **[verificado]**. **Somente leituras (GET)**: nunca
`PATCH /items`, nunca criar item.

**Credenciais e privilégio.**

- A apiKey da Pluggy vem de `POST /auth` com `CLIENT_ID`/`CLIENT_SECRET` a cada
  execução; nunca é persistida em tabela.
- As funções rodam **sem sessão de usuário** e usam a `service_role` injetada
  pelo runtime do Supabase (a chave não é copiada para lugar nenhum). É a
  **única exceção** à regra "nunca `service_role`", que continua valendo para
  scripts, front-end e repositório. As funções só escrevem nas tabelas da
  integração e chamam `casar_transacoes_bancarias()`.
- Secrets: `PLUGGY_CLIENT_ID`, `PLUGGY_CLIENT_SECRET`, `WEBHOOK_SECRET`,
  `SYNC_SECRET`, `OWNER_USER_ID`, `OWNER_CPF`.

### 14.9 Saúde da conexão (falha silenciosa)

Quando um consentimento é **revogado ou expira**, os endpoints de dados
devolvem **listas vazias, sem erro** **[verificado]**. Por padrão o consentimento
Open Finance não expira (alguns conectores têm prazo de 1 ano); o risco real é a
revogação. Sem tratamento, a sincronização "funciona" e o usuário volta ao
problema original sem perceber.

- `conexoes_pluggy` guarda `status`, `ultima_atualizacao` e `ultima_transacao_em`,
  alimentados por `GET /items/{id}` (eventos de item e rotina diária).
- `v_saude_conexoes.atrasada = true` quando: última atualização há mais de 48 h;
  status diferente de atualizado; consentimento revogado; ou nenhuma transação
  nova em conta que costuma ter movimento por mais de N dias (N inicial: 7;
  **[a validar]**, porque a lista vazia não é erro).
- O app mostra um **banner** no Resumo ("Sincronização bancária atrasada desde
  dd/mm — reconecte no Meu Pluggy"). Renovar o consentimento é feito no Meu
  Pluggy, não no app.

### 14.10 Faturas: pago × devido

`GET /bills` (Open Finance) traz `dueDate`, `totalAmount`, `minimumPaymentAmount`,
`allowsInstallments`, `payments[]` (`valueType` integral/mínimo/outro, valor,
data, modo) e `financeCharges[]` (IOF, juros, multa) **[verificado]**. A
disponibilidade via item MeuPluggy **[a validar]** na Fase A.

- `v_faturas_conciliacao` compara `pago` com `total`. Pago a menos = fatura
  **rolada/financiada**; o app mostra a diferença e os encargos e oferece
  registrar o parcelamento da fatura.
- O pagamento de uma fatura aparece na **fatura seguinte** (regra de quitação:
  `total(N) + encargos(N+1) = pagamentos(N+1)`), então a conciliação chega com
  defasagem. O `PAGAMENTO_FATURA` do lado cartão serve de sinal mais cedo.
- `billId` liga cada compra à sua fatura. O vencimento real da fatura pode, no
  futuro, **corrigir** o ciclo estimado pelo dia 27/03 (a Pluggy não distingue
  fatura aberta de fechada no Open Finance, então o fechamento continua
  estimado). Refinamento fora do escopo da v2 inicial.
- **Modelagem do parcelamento de fatura: em aberto** (14.15). A regra de caixa
  da seção 4 assume pagamento integral da fatura; ao financiar parte dela, é
  preciso evitar contar duas vezes (compras no ciclo da fatura **e** parcelas
  futuras). Definir com dados reais de `/bills`.

### 14.11 Front-end (v2)

Acréscimos ao escopo da seção 9:

1. **Para revisar** (nova tela, rota por hash). Cada linha já vem preenchida
   (categoria, meio e tipo sugeridos). Ações: **Confirmar** (um toque, usa a
   sugestão), **Editar e confirmar**, **Ignorar**, **Vincular a…** (candidatos
   de casamento) e **Criar parcelamento** (quando parcelada sem cadastro). Cada
   linha mostra claramente se **já conta no saldo** (provisória) ou **não**.
2. **Revisadas** (visão secundária): confirmadas e ignoradas, com **desfazer**.
3. **Resumo:** contador de itens para revisar, valor aguardando confirmação
   **fora** do saldo (Pix e entradas), valor provisório **dentro** do saldo, e o
   banner de saúde da conexão (14.9).
4. **Extrato:** itens provisórios com selo "provisório"; origem `banco` nas
   linhas vindas da integração.
5. **Configuração:** regras de categoria (listar, editar, desativar) e estado
   das conexões.
6. **Lançamento rápido continua existindo** (dinheiro em espécie, o que o banco
   não vê). O motor de casamento evita duplicar o que depois aparecer no banco.

Todas as ações de revisão passam por **RPC** (`confirmar_transacao`,
`ignorar_transacao`, `vincular_transacao`, `desfazer_transacao`); o app não
escreve direto nas tabelas da integração. Nenhum cálculo no cliente (princípio
da seção 3).

### 14.12 Segurança e portões

- **RLS em todas as tabelas novas**, mesma policy `user_id = auth.uid()`.
- **`GRANT`s explícitos** (lição da seção 8): para `authenticated`, apenas
  `SELECT` em `transacoes_bancarias`, `conexoes_pluggy`, `eventos_pluggy` e
  `faturas_cartao`; CRUD em `regras_categoria`; `SELECT` nas views novas;
  `EXECUTE` nas RPCs. **Nenhum `INSERT/UPDATE/DELETE` direto** do cliente nas
  tabelas da integração. `anon`: no máximo `SELECT` (RLS devolve zero linhas).
- **RPCs `security definer`** com `set search_path = public` e filtro explícito
  `user_id = auth.uid()` em toda leitura e escrita. É a armadilha clássica de
  `security definer`; coberta por teste.
- **Portão 3 — contagem única (pgTAP).** Casos mínimos: crédito/débito
  provisório conta; Pix e entradas não contam até confirmar; confirmar **não
  soma duas vezes** (provisório → avulso); `vinculada` conta só pelo cadastro;
  liquidação de fatura não conta; `ignorada` e `removida` não contam; transação
  recriada pela Pluggy com **id novo e mesmo `provider_id`** não duplica;
  transferência própria não conta; criar parcelamento e re-casar não duplica.
- **Portão 4 — RLS/GRANT dos objetos novos.** `anon` sem sessão lê zero linhas
  em todas as tabelas novas (via API REST real, também no cloud); usuário B não
  confirma, ignora nem lê transação do usuário A (padrão do `02_rls_leak.sql`).
- **Portão 5 — webhook e segredos.** Requisição sem cabeçalho ou com cabeçalho
  errado → `401` e **nada gravado**; payload com campos extras → linha gravada
  **sem** CPF/CNPJ/conta; busca no repositório e no histórico git não encontra
  nenhum dos secrets de 14.8; teste local do webhook com payload falso.
- **Portão A — reconhecimento documentado** antes de qualquer código (14.13).
- **Portão G — dry-run** da importação inicial revisado antes de gravar.

### 14.13 Fases de implementação

Executar **antes** da Fase 7 (Power BI). Não avançar sem o portão da fase verde.

**Fase A — Reconhecimento (somente leitura, local).** Script
`integracao/reconhecimento.mjs`, executado no Claude Code, com credenciais por
variável de ambiente ou prompt (como o `importar.mjs`). Para cada conta imprime
**somente contagens e presença de campos**: tipo e subtipo da conta; nº de
transações em 12 meses; distribuição de `tipo_operacao`/`paymentMethod`; % com
`paymentData`, com `providerId`, com `billId`, `installmentNumber`,
`totalInstallments` e `paymentType`; nº de faturas em `/bills`; e do item
`status`, `consentExpiresAt` e última atualização. **Proibido imprimir nomes,
valores, descrições ou documentos.** Perguntas a responder: (1) em quais bancos o
`paymentData` chega e se permite reconhecer o destinatário; (2) se o item
MeuPluggy expõe faturas e `providerId`; (3) como aparecem Pix, compra no débito,
débito automático, pagamento de fatura (nos dois lados) e salário; (4) como cada
cartão posta parcelas (todas de uma vez ou mês a mês). **Resultado registrado em
14.15 antes da Fase C.** Usa uma única vez a cota de histórico; **não repetir em
laço**.

**Fase B — Ambiente.** Projeto-cópia (14.3), `db push`, `--wipe-movimentos`,
keepalive próprio, RLS verificado no cloud.

**Fase C — Schema e motor (SQL).** Tabelas, enum, `casar_transacoes_bancarias()`,
views, RPCs, `GRANT`s. **Portões 3 e 4.**

**Fase D — Ingestão.** `pluggy-webhook`, `pluggy-sync`, `registrar-webhook.mjs`,
`sync.yml`, secrets. **Portão 5.**

**Fase E — App.** Telas e contadores de 14.11, banner de saúde.

**Fase F — Faturas.** `faturas_cartao`, `v_faturas_conciliacao`, e fechar a
modelagem do parcelamento de fatura com dados reais.

**Fase G — Importação inicial.** Uma única busca de 12 meses (cota histórica);
se falhar, **não repetir em laço**. Primeiro em modo de simulação, listando
contagens por estado e os não casados; depois grava. **Portão G.** Idempotente
e reexecutável (a deduplicação por `chave_dedupe` garante).

Depois: **Fase 7 (Power BI)** consome `v_fluxo` (já com `provisorio`) e as views
da seção 7. Nada além disso é conectado ao BI.

### 14.14 Limites e armadilhas documentados

Para o Claude Code não redescobrir a cada tarefa **[verificado]**:

- Sync do Meu Pluggy a cada 24 h; o item proxy **não** pode ser atualizado
  manualmente. Sem tempo real.
- Consentimento revogado/expirado → listas vazias **sem erro** (14.9).
- Ids de transação mudam em delete + recreate → usar `provider_id` (14.7).
- Webhooks: resposta em ≤ 10 s; 3 tentativas (0, ~15 min, ~2 h); 400, 401, 403,
  404 e 405 **não** são reenviados; mesmas transações podem reaparecer em
  atualizações repetidas no mesmo dia.
- A atualização diária busca só os últimos 7 dias; mudanças em transações mais
  antigas (`PENDING → POSTED`, `billId`, parcelas novas) só chegam por webhook ou
  pela conferência (14.8).
- `PENDING` = fatura ainda aberta (sem `billId`); `POSTED` = fatura vencida (com
  `billId`). Não dá para distinguir fatura aberta de fechada.
- **Parcelas:** cada banco posta de um jeito (todas de uma vez, uma por mês, ou só
  a atual); não há id que agrupe as parcelas de uma compra; o Open Finance não
  devolve o total da compra. Agrupar por `parcela_numero`, `parcela_total`, data
  da primeira parcela e comerciante. **Não contar com parcelas futuras da
  Pluggy**: os parcelamentos cadastrados continuam sendo a fonte da projeção.
- `paymentData` existe nos dois tipos de conexão, mas o quão completo vem varia
  por instituição, e só algumas transações de pagamento/transferência o trazem.
- Open Finance exige `GET /v2/transactions` por cursor; `ids` ≤ 500.
- Conectores diretos de pessoa física estão sendo descontinuados; usar apenas
  Open Finance (via MeuPluggy).

### 14.15 Decisões, pendências e correções

**Decisões do usuário [decidido]**

- Integração direta pela API da Pluggy, via Meu Pluggy (14.2).
- Projeto Supabase novo, cópia do atual; atual intacto; limpar movimentos e
  importar pela API (14.3).
- Aba **"Para revisar"** (nome); saem da aba após confirmadas (14.5).
- Contagem imediata só para crédito, débito e parcelamentos; Pix, transferências
  e demais só após confirmar (14.5).
- Teste pgTAP de contagem única (Portão 3).
- Quer comparar o valor pago da fatura com o devido (14.10).
- Tratar Pix de saída cujo destinatário seja o próprio usuário (14.6).

**Em aberto**

1. **Destino do projeto-cópia** depois de validado: virar produção ou ser
   descartado.
2. **Pix de saída:** contar automaticamente quando o destinatário já foi
   confirmado antes como despesa? Padrão adotado até decisão: **não**, só após
   confirmar.
3. **Transferência própria:** padrão atual é `para_revisar` com "ignorar" a um
   toque; automatizar o ignorar só depois de semanas de uso.
4. **Ciclos anteriores à janela da API (~12 meses)** no projeto-cópia ficam sem
   `execucoes`: os recorrentes aparecem como previstos, não pagos. Decidir entre
   ajustar `data_inicio` dos recorrentes para o primeiro ciclo da janela ou
   aceitar histórico incompleto na cópia.
5. **Modelagem do parcelamento de fatura** (14.10).
6. **Fase A:** `paymentData`, faturas e `providerId` no item MeuPluggy; como
   aparecem débito automático, compra no débito e pagamento de fatura.
7. **Resultado do reconhecimento (Fase A):** *preencher aqui antes da Fase C.*

**Correção a registros anteriores (out/2026).** A nota da remigração v2 na
seção 11 registra "Financiamento Uno e sua entrada" como pagos por `pix`. O
usuário informa que **financiamentos e empréstimos são sempre pagos por débito
direto automático na conta**. Ação: corrigir `meio_pagamento` para `debito` nos
cadastros de financiamento e empréstimo (`recorrentes` e `parcelamentos`),
conferindo separadamente a entrada do financiamento, que, se foi paga à parte,
pode ter sido Pix de verdade. Nenhuma previsão muda (pix e débito caem no mesmo ciclo em
`ciclo_caixa`), mas com a integração o meio passa a decidir o tratamento.

### 14.16 Revisão da seção 14 (nov/2026)

Revisão feita com o Claude Code, conferindo as afirmações **[verificado]** na
documentação da Pluggy (servidor MCP `pluggy-docs`, nov/2026). As afirmações
centrais conferem: conector MeuPluggy (id 200) gratuito para uso pessoal e não
afetado pelo fim do trial; item proxy sem atualização manual; webhooks com 3
tentativas e sem reenvio de 401; consentimento revogado devolvendo listas vazias
sem erro. Acréscimos e correções:

**Decisões [decidido]**

- **Começar sem webhook.** A ingestão inicial é só a `pluggy-sync`, **uma vez
  por dia**. O Meu Pluggy só atualiza a cada 24 h, então o webhook ganharia no
  máximo algumas horas, e ele é a única porta pública sem JWT da integração.
  `pluggy-webhook`, `eventos_pluggy` e `registrar-webhook.mjs` ficam para depois,
  se fizer falta; o desenho de 14.8 continua valendo para quando entrarem.
  Consequência: a conferência diária (14.8, item a) deixa de ser rede de
  segurança e passa a ser o caminho principal.

**Correções [verificado]**

- **Cabeçalho customizado do webhook:** hoje também se configura pelo
  Dashboard (Webhooks, só o Owner), não só pela API, como dizia 14.8.
- **Assinatura HMAC do webhook:** a Pluggy assina cada notificação em
  `X-Pluggy-Signature: t=<unix>,v1=<hex>`, HMAC-SHA256 de `<t>.<corpo cru>` com
  o segredo `whsec_…` gerado no Dashboard. É a única camada que prova origem
  **e** integridade, e já protege de replay (tolerância de 5 min em `t`).
  Quando o webhook entrar: exigir **assinatura e cabeçalho secreto**, validar
  sobre o corpo cru antes do parse, comparar em tempo constante, conferir
  `clientId` e reler o recurso pela API antes de agir. Na troca de segredo,
  responder `503` (que é reenviado), não `401`.
- **Sinal dos valores:** no cartão (`CREDIT`), valor **positivo** é compra e
  negativo é pagamento/estorno; na conta (`BANK`), negativo é saída. A
  ingestão normaliza por `tipo_conta` antes de preencher `sentido`.

**Correção de desenho: contagem dupla antes do casamento**

A tabela de 14.5 conta crédito e débito como provisórios na hora. Isso soma duas
vezes quando o mesmo gasto já está no saldo por um cadastro que ainda não casou:

- assinatura no crédito cadastrada como recorrente cujo valor mudou (câmbio,
  reajuste) e por isso não casou: provisória **e** recorrente previsto;
- compra lançada à mão com mais de um candidato (o casamento vira só sugestão):
  avulso **e** provisória.

**Regra nova:** uma transação de crédito/débito só conta como provisória **se
não houver nenhum candidato de casamento** (recorrente ainda não pago no ciclo,
ou avulso parecido sem `transacao_banco_id`). Com candidato, quem já conta é o
cadastro, e a transação espera revisão em "Para revisar". Entra como caso no
**Portão 3**.

**Oportunidade registrada (não é escopo agora)**

- `GET /accounts` traz o saldo atual de cada conta. Pode virar a âncora
  automática de `saldos` (hoje digitada em Configuração) e mostrar de verdade
  quando a conta entrou no cheque especial (seção 7, juros na projeção).
