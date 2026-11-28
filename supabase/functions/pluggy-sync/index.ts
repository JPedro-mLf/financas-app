// Fase D -- ingestao Open Finance (ESPECIFICACAO.md 14.8, com as decisoes de
// 14.16/14.17): sincronizacao diaria SEM webhook.
//
// Acionada pelo GitHub Actions (.github/workflows/sync.yml) com o cabecalho
// `x-sync-secret`, que so serve para DISPARAR a sincronizacao (nao le dados).
// Somente leituras (GET) na Pluggy: nunca PATCH /items, nunca cria item.
//
// Seguranca (R2/R3):
//   - Credenciais so em secrets do Supabase; a apiKey da Pluggy vem de
//     POST /auth a cada execucao e nunca e guardada.
//   - Lista fixa de campos gravados. paymentData (CPF/CNPJ, agencia, conta,
//     nomes) e DESCARTADO; so o booleano `transferencia_propria` sobrevive.
//   - Logs e resposta: so contagens. Nunca descricoes, valores ou documentos.
//   - Escreve direto no Postgres (SUPABASE_DB_URL, injetada pelo runtime), sem
//     depender das chaves da API.
//
// Corpo (opcional): { "dias": 14, "simular": false }
//   dias    -- janela relida por conta (1..400). Diario: 14; importacao: 365.
//   simular -- conta o que seria gravado, sem gravar nada (Portao G).

import postgres from 'npm:postgres@3.4.5';

const API = 'https://api.pluggy.ai';

type TransacaoPluggy = {
  id: string;
  description: string;
  amount: number;
  amountInAccountCurrency?: number;
  currencyCode?: string;
  date: string;
  type: 'DEBIT' | 'CREDIT';
  status?: string;
  order?: number;
  operationType?: string | null;
  paymentData?: {
    paymentMethod?: string;
    payer?: { documentNumber?: { value?: string } };
    receiver?: { documentNumber?: { value?: string } };
  } | null;
  creditCardMetadata?: {
    installmentNumber?: number;
    totalInstallments?: number;
    purchaseDate?: string;
    billId?: string;
    billForecastDate?: string;
    paymentType?: 'SINGLE' | 'INSTALLMENT';
  };
};

// Mesma regra de parcela_do_texto() (migration 20261128000006): "6/10" com
// total entre 2 e 48 e numero <= total; "21/11/2026" (data) nao conta.
function parcelaDoTexto(descricao: string): { numero: number; total: number } | null {
  const m = /(?:^|\D)(\d{1,2})\/(\d{1,2})(?:\D|$)/.exec(descricao ?? '');
  if (!m) return null;
  const numero = Number(m[1]);
  const total = Number(m[2]);
  return total >= 2 && total <= 48 && numero >= 1 && numero <= total ? { numero, total } : null;
}

function env(nome: string): string {
  const v = Deno.env.get(nome);
  if (!v) throw new Error(`secret ausente: ${nome}`);
  return v;
}

// Comparacao em tempo constante (o tamanho do segredo nao e segredo).
function mesmoSegredo(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  if (x.length !== y.length) return false;
  let dif = 0;
  for (let i = 0; i < x.length; i++) dif |= x[i] ^ y[i];
  return dif === 0;
}

async function sha256(texto: string): Promise<string> {
  const h = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(texto));
  return [...new Uint8Array(h)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

const soDigitos = (s?: string) => (s ?? '').replace(/\D/g, '');

async function pluggy(apiKey: string, caminho: string) {
  const r = await fetch(`${API}${caminho}`, { headers: { 'X-API-KEY': apiKey } });
  if (!r.ok) throw new Error(`GET ${caminho.split('?')[0]} -> ${r.status}`);
  return r.json();
}

// Meio de pagamento inferido (14.6). Cartao e sempre credito; na conta, pelo
// tipo de operacao.
function meioInferido(tipoConta: string, t: TransacaoPluggy): string {
  if (tipoConta === 'CREDIT') return 'credito';
  const op = t.operationType ?? '';
  const metodo = t.paymentData?.paymentMethod ?? '';
  if (op === 'PIX' || metodo === 'PIX') return 'pix';
  if (op === 'BOLETO' || metodo === 'BOLETO') return 'boleto';
  if (op === 'FOLHA_PAGAMENTO') return 'folha';
  return 'debito';
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('metodo nao permitido', { status: 405 });
  // Primeira instrucao: o segredo. Falhou -> 401 e nada acontece.
  if (!mesmoSegredo(req.headers.get('x-sync-secret') ?? '', env('SYNC_SECRET'))) {
    return new Response('nao autorizado', { status: 401 });
  }

  const corpo = await req.json().catch(() => ({}));
  const dias = Math.min(Math.max(Number(corpo.dias ?? 14) || 14, 1), 400);
  const simular = corpo.simular === true;
  const desde = new Date(Date.now() - dias * 864e5).toISOString().slice(0, 10);

  const uid = env('OWNER_USER_ID');
  const cpf = soDigitos(Deno.env.get('OWNER_CPF'));
  const itens = env('PLUGGY_ITEMS').split(',').map((p) => p.trim()).filter(Boolean).map((p) => {
    const [banco, id] = p.includes(':') ? p.split(':') : ['?', p];
    return { banco: banco.trim(), id: id.trim() };
  });

  const sql = postgres(env('SUPABASE_DB_URL'), { prepare: false, max: 1 });
  const resumo: Record<string, unknown>[] = [];

  try {
    const auth = await fetch(`${API}/auth`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ clientId: env('PLUGGY_CLIENT_ID'), clientSecret: env('PLUGGY_CLIENT_SECRET') }),
    });
    if (!auth.ok) throw new Error(`POST /auth -> ${auth.status}`);
    const apiKey = (await auth.json()).apiKey as string;

    for (const { banco, id: itemId } of itens) {
      const parcial: Record<string, unknown> = { banco };
      try {
        const item = await pluggy(apiKey, `/items/${itemId}`);
        if (!simular) {
          await sql`
            insert into conexoes_pluggy (user_id, item_id, banco, status, ultima_atualizacao, consentimento_expira_em, verificada_em)
            values (${uid}, ${itemId}, ${banco}, ${item.status ?? null}, ${item.lastUpdatedAt ?? null},
                    ${item.consentExpiresAt ?? null}, now())
            on conflict (user_id, item_id) do update
              set banco = excluded.banco, status = excluded.status,
                  ultima_atualizacao = excluded.ultima_atualizacao,
                  consentimento_expira_em = excluded.consentimento_expira_em,
                  verificada_em = now()`;
        }

        const contas = (await pluggy(apiKey, `/accounts?itemId=${itemId}`)).results ?? [];
        let novas = 0, existentes = 0, removidas = 0, lidas = 0;

        for (const conta of contas) {
          if (!simular) {
            await sql`
              insert into contas_pluggy (user_id, conta_pluggy_id, item_id, banco, tipo, subtipo, saldo, saldo_em)
              values (${uid}, ${conta.id}, ${itemId}, ${banco}, ${conta.type}, ${conta.subtype ?? null},
                      ${conta.balance ?? null}, now())
              on conflict (user_id, conta_pluggy_id) do update
                set saldo = excluded.saldo, saldo_em = now(), subtipo = excluded.subtipo`;
          }

          const ts: TransacaoPluggy[] = [];
          let consulta: string | null = `?accountId=${conta.id}&dateFrom=${desde}`;
          while (consulta) {
            const pagina = await pluggy(apiKey, `/v2/transactions${consulta}`);
            ts.push(...pagina.results);
            consulta = pagina.next;
          }
          lidas += ts.length;

          // Chave de deduplicacao (14.17): providerId nao vem pelo MeuPluggy e
          // o id da Pluggy muda em delete+recreate. Hash do conteudo + ordinal
          // entre identicas (duas compras iguais no mesmo dia sao legitimas).
          const linhas = [];
          const grupos = new Map<string, TransacaoPluggy[]>();
          for (const t of ts) {
            const valor = Math.abs(t.amountInAccountCurrency ?? t.amount);
            const base = await sha256(`${conta.id}|${t.date.slice(0, 10)}|${valor.toFixed(2)}|${t.description}`);
            grupos.set(base, [...(grupos.get(base) ?? []), t]);
          }
          for (const [base, grupo] of grupos) {
            grupo.sort((a, b) => (a.order ?? 0) - (b.order ?? 0) || a.id.localeCompare(b.id));
            grupo.forEach((t, i) => {
              const valor = Math.abs(t.amountInAccountCurrency ?? t.amount);
              const sentido = t.type === 'CREDIT' ? 'receita' : 'despesa';
              // Documento do outro lado da transferencia: comparado e DESCARTADO.
              const docOutroLado = soDigitos(
                sentido === 'despesa'
                  ? t.paymentData?.receiver?.documentNumber?.value
                  : t.paymentData?.payer?.documentNumber?.value,
              );
              const cc = t.creditCardMetadata;
              // Parcela escrita so no texto ("SERGIO S 6/10"); mesma regra de
              // parcela_do_texto() no banco.
              const parcelaTexto = conta.type === 'CREDIT' && !cc?.totalInstallments
                ? parcelaDoTexto(t.description) : null;
              linhas.push({
                user_id: uid,
                pluggy_id: t.id,
                chave_dedupe: `${base}#${i}`,
                conta_pluggy_id: conta.id,
                tipo_conta: conta.type,
                data: t.date.slice(0, 10),
                valor: valor.toFixed(2),
                sentido,
                descricao: t.description,
                tipo_operacao: t.operationType ?? null,
                meio_inferido: meioInferido(conta.type, t),
                status_pluggy: t.status ?? null,
                bill_id: cc?.billId ?? null,
                fatura_prevista: cc?.billForecastDate ?? null,
                parcela_numero: cc?.installmentNumber ?? parcelaTexto?.numero ?? null,
                parcela_total: cc?.totalInstallments ?? parcelaTexto?.total ?? null,
                data_compra_original: cc?.purchaseDate ? cc.purchaseDate.slice(0, 10) : null,
                tipo_pagamento: cc?.paymentType ?? null,
                // 3 estados (14.21): true = para si; false = terceiro
                // identificado (Pix conta na hora); null = desconhecido (sem
                // OWNER_CPF ou sem documento) -- continua fora do saldo.
                transferencia_propria: cpf.length === 11 && docOutroLado ? docOutroLado === cpf : null,
              });
            });
          }

          const chaves = linhas.map((l) => l.chave_dedupe);
          const jaExistem = chaves.length
            ? (await sql`select count(*)::int as n from transacoes_bancarias
                         where user_id = ${uid} and chave_dedupe = any(${chaves})`)[0].n
            : 0;
          existentes += jaExistem;
          novas += linhas.length - jaExistem;
          if (simular || linhas.length === 0) continue;

          await sql`
            insert into transacoes_bancarias ${sql(linhas)}
            on conflict (user_id, chave_dedupe) do update
              set pluggy_id = excluded.pluggy_id,
                  status_pluggy = excluded.status_pluggy,
                  bill_id = excluded.bill_id,
                  fatura_prevista = excluded.fatura_prevista,
                  tipo_pagamento = excluded.tipo_pagamento,
                  parcela_numero = excluded.parcela_numero,
                  parcela_total = excluded.parcela_total,
                  transferencia_propria = excluded.transferencia_propria,
                  removida_em = null,
                  estado = case when transacoes_bancarias.estado = 'removida'
                                then 'para_revisar'::estado_banco else transacoes_bancarias.estado end,
                  atualizada_em = now()`;

          // Sumiu do banco dentro da janela relida: removida (14.5). Lista
          // vazia NAO conta -- e o sintoma de consentimento vencido (14.9) e
          // apagaria o historico. Vinculadas/confirmadas so recebem o aviso.
          const r = await sql`
            update transacoes_bancarias
               set estado = case when estado in ('para_revisar', 'ignorada')
                                 then 'removida'::estado_banco else estado end,
                   removida_em = now(), atualizada_em = now()
             where user_id = ${uid} and conta_pluggy_id = ${conta.id}
               and data >= ${desde} and removida_em is null and estado <> 'removida'
               and not (chave_dedupe = any(${chaves}))`;
          removidas += r.count;
        }

        if (!simular) {
          await sql`
            update conexoes_pluggy c
               set ultima_transacao_em = (select max(t.data) from transacoes_bancarias t
                                          join contas_pluggy cp on cp.user_id = t.user_id
                                                               and cp.conta_pluggy_id = t.conta_pluggy_id
                                          where t.user_id = ${uid} and cp.item_id = ${itemId}
                                            and t.data <= current_date)
             where c.user_id = ${uid} and c.item_id = ${itemId}`;
        }
        Object.assign(parcial, { contas: contas.length, lidas, novas, existentes, removidas });
      } catch (e) {
        parcial.erro = (e as Error).message;
      }
      resumo.push(parcial);
    }

    let casadas: number | null = null;
    if (!simular) {
      casadas = (await sql`select casar_transacoes_bancarias(${uid}) as n`)[0].n;
    }
    const corpoResposta = { simular, dias, desde, itens: resumo, casadas_automaticamente: casadas };
    console.log(JSON.stringify(corpoResposta));
    return Response.json(corpoResposta, { status: resumo.some((r) => r.erro) ? 207 : 200 });
  } catch (e) {
    console.error(`falhou: ${(e as Error).message}`);
    // Erro temporario: 5xx (o GitHub Actions marca a execucao como falha).
    return Response.json({ erro: (e as Error).message }, { status: 500 });
  } finally {
    await sql.end();
  }
});
