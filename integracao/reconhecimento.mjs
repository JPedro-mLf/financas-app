// Fase A -- reconhecimento da API da Pluggy (ESPECIFICACAO.md secao 14.13).
//
// Somente leitura (GET), executado localmente. Imprime APENAS contagens,
// datas e presenca de campos: nunca nomes, valores, descricoes, documentos,
// numeros de conta ou saldos. O resultado vai para a secao 14.15.
//
// Credenciais: arquivo FORA do repositorio (o repo e publico), por padrao
// %USERPROFILE%\.financas\pluggy.env, ou o caminho em PLUGGY_ENV_FILE:
//
//   PLUGGY_CLIENT_ID=...
//   PLUGGY_CLIENT_SECRET=...
//   PLUGGY_ITEMS=Inter:<itemId>,Nubank:<itemId>,...
//
// Os itens do MeuPluggy so leem dados que a Pluggy ja guarda (o proxy nao
// aciona o banco), mas mesmo assim: rodar UMA vez, nao em laco.
//
// Uso: node integracao/reconhecimento.mjs

import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';

const API = 'https://api.pluggy.ai';
const MESES_HISTORICO = 12;

function carregarConfig() {
  const arquivo = process.env.PLUGGY_ENV_FILE ?? path.join(homedir(), '.financas', 'pluggy.env');
  if (existsSync(arquivo)) process.loadEnvFile(arquivo);

  const clientId = process.env.PLUGGY_CLIENT_ID;
  const clientSecret = process.env.PLUGGY_CLIENT_SECRET;
  const itens = (process.env.PLUGGY_ITEMS ?? '')
    .split(',')
    .map((par) => par.trim())
    .filter(Boolean)
    .map((par) => {
      const [rotulo, id] = par.includes(':') ? par.split(':') : ['?', par];
      return { rotulo: rotulo.trim(), id: id.trim() };
    });

  const faltando = [
    !clientId && 'PLUGGY_CLIENT_ID',
    !clientSecret && 'PLUGGY_CLIENT_SECRET',
    itens.length === 0 && 'PLUGGY_ITEMS',
  ].filter(Boolean);
  if (faltando.length) {
    console.error(`Faltando: ${faltando.join(', ')} (arquivo procurado: ${arquivo}).`);
    process.exit(1);
  }
  return { clientId, clientSecret, itens };
}

// Erros mostram so status e mensagem da API -- nunca cabecalhos (apiKey).
async function chamar(apiKey, caminho) {
  const resp = await fetch(`${API}${caminho}`, { headers: { 'X-API-KEY': apiKey } });
  if (!resp.ok) {
    const corpo = await resp.json().catch(() => ({}));
    throw new Error(`GET ${caminho.split('?')[0]} -> ${resp.status} ${corpo.codeDescription ?? ''} ${corpo.message ?? ''}`.trim());
  }
  return resp.json();
}

async function autenticar({ clientId, clientSecret }) {
  const resp = await fetch(`${API}/auth`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ clientId, clientSecret }),
  });
  if (!resp.ok) throw new Error(`POST /auth -> ${resp.status} (confira CLIENT_ID/SECRET)`);
  return (await resp.json()).apiKey;
}

async function todasTransacoes(apiKey, accountId, dateFrom) {
  const lista = [];
  let consulta = `?accountId=${accountId}&dateFrom=${dateFrom}`;
  while (consulta) {
    const pagina = await chamar(apiKey, `/v2/transactions${consulta}`);
    lista.push(...pagina.results);
    consulta = pagina.next;
  }
  return lista;
}

const dia = (iso) => (iso ? String(iso).slice(0, 10) : '-');
const pct = (n, total) => (total ? `${Math.round((100 * n) / total)}%` : '-');

function distribuicao(lista, chave) {
  const contagem = new Map();
  for (const t of lista) {
    const k = chave(t) ?? '(vazio)';
    contagem.set(k, (contagem.get(k) ?? 0) + 1);
  }
  return [...contagem.entries()].sort((a, b) => b[1] - a[1]).map(([k, n]) => `${k}=${n}`).join(', ');
}

function presenca(lista, campos) {
  return campos
    .map(([rotulo, teste]) => `${rotulo} ${pct(lista.filter(teste).length, lista.length)}`)
    .join(' | ');
}

function resumirTransacoes(ts, tipoConta) {
  if (ts.length === 0) return ['    transacoes: 0'];
  const datas = ts.map((t) => dia(t.date)).sort();
  const criadas = ts.map((t) => String(t.createdAt)).sort();
  const linhas = [
    `    transacoes (${MESES_HISTORICO} meses): ${ts.length} | de ${datas[0]} a ${datas.at(-1)} | ingerida mais recente: ${dia(criadas.at(-1))}`,
    `    type: ${distribuicao(ts, (t) => t.type)}`,
    `    status: ${distribuicao(ts, (t) => t.status)}`,
    `    operationType: ${distribuicao(ts, (t) => t.operationType)}`,
    `    paymentMethod: ${distribuicao(ts, (t) => t.paymentData?.paymentMethod)}`,
    `    presenca: ${presenca(ts, [
      ['providerId', (t) => t.providerId],
      ['providerCode', (t) => t.providerCode],
      ['paymentData', (t) => t.paymentData],
      ['doc recebedor', (t) => t.paymentData?.receiver?.documentNumber?.value],
      ['doc pagador', (t) => t.paymentData?.payer?.documentNumber?.value],
      ['merchant', (t) => t.merchant],
      ['category', (t) => t.category],
    ])}`,
  ];
  if (tipoConta === 'CREDIT') {
    linhas.push(
      `    cartao: ${presenca(ts, [
        ['billId', (t) => t.creditCardMetadata?.billId],
        ['billForecastDate', (t) => t.creditCardMetadata?.billForecastDate],
        ['purchaseDate', (t) => t.creditCardMetadata?.purchaseDate],
        ['installmentNumber', (t) => t.creditCardMetadata?.installmentNumber],
        ['totalInstallments', (t) => t.creditCardMetadata?.totalInstallments],
        ['paymentType', (t) => t.creditCardMetadata?.paymentType],
      ])}`,
      `    cartao paymentType: ${distribuicao(ts, (t) => t.creditCardMetadata?.paymentType)}`,
    );
  }
  return linhas;
}

async function main() {
  const config = carregarConfig();
  const apiKey = await autenticar(config);
  const dateFrom = new Date(Date.now() - MESES_HISTORICO * 30.5 * 864e5).toISOString().slice(0, 10);

  console.log(`Fase A -- reconhecimento (${new Date().toISOString().slice(0, 10)}), ${config.itens.length} item(ns)\n`);

  for (const { rotulo, id } of config.itens) {
    console.log(`== ${rotulo}`);
    try {
      const item = await chamar(apiKey, `/items/${id}`);
      console.log(
        `  item: conector=${item.connector?.name} (id ${item.connector?.id}, openFinance=${item.connector?.isOpenFinance})` +
          ` status=${item.status} execucao=${item.executionStatus}` +
          ` ultimaAtualizacao=${dia(item.lastUpdatedAt)} proximaAuto=${dia(item.nextAutoSyncAt)}` +
          ` consentimentoExpira=${dia(item.consentExpiresAt)}` +
          ` transacoesAtualizadasEm=${dia(item.statusDetail?.transactions?.lastUpdatedAt)}` +
          (item.error ? ` ERRO=${item.error.code}` : ''),
      );

      const contas = (await chamar(apiKey, `/accounts?itemId=${id}`)).results ?? [];
      console.log(`  contas: ${contas.length}`);
      for (const [i, conta] of contas.entries()) {
        console.log(`  - conta ${i + 1}: ${conta.type}/${conta.subtype} | saldo informado: ${conta.balance != null ? 'sim' : 'nao'}`);
        const ts = await todasTransacoes(apiKey, conta.id, dateFrom);
        for (const linha of resumirTransacoes(ts, conta.type)) console.log(linha);
        if (conta.type === 'CREDIT') {
          const faturas = (await chamar(apiKey, `/bills?accountId=${conta.id}`)).results ?? [];
          console.log(
            `    faturas: ${faturas.length}` +
              (faturas.length
                ? ` | ${presenca(faturas, [
                    ['dueDate', (f) => f.dueDate],
                    ['minimo', (f) => f.minimumPaymentAmount != null],
                    ['payments', (f) => f.payments?.length],
                    ['financeCharges', (f) => f.financeCharges?.length],
                  ])}`
                : ''),
          );
        }
      }
    } catch (erro) {
      console.log(`  falhou: ${erro.message}`);
    }
    console.log('');
  }
}

main().catch((erro) => {
  console.error(`FALHOU: ${erro.message}`);
  process.exit(1);
});
