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
| `v_previsao` | Saldo acumulado projetado ao longo de `horizonte_meses` |
| `v_alertas` | Sinaliza saldo negativo previsto dentro do horizonte |

Decisões de design tomadas na implementação:

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
   e campo para valor realizado (usado nos itens `estimado`).
5. **Resumo** — saldo do ciclo, previsto vs. realizado, previsão do horizonte,
   alerta de saldo negativo.
6. **Configuração** — parâmetros do ciclo, categorias, descontos em folha,
   saldo apurado (conciliação usada pela previsão do horizonte).

Fora do escopo da v1: gráficos elaborados (é papel do Power BI), múltiplos
usuários, anexos, integração bancária. Também fora do v1: tela de edição de
recorrentes/parcelamentos já cadastrados (por enquanto, ajustes desse tipo
são feitos direto no Table Editor do Supabase Studio).

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
- **Fase 7 (Power BI):** não iniciada.
