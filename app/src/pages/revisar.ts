import { supabase } from '../lib/supabaseClient';
import { formatBRL, formatData, rotuloCiclo, rotuloMeio, rotuloPeriodo, todayISO } from '../lib/format';
import { periodoDoCiclo } from '../lib/ciclo';

// Tela "Para revisar" (ESPECIFICACAO.md 14.11). So exibe e chama RPCs: quem
// decide o que conta no saldo, o ciclo e os candidatos e o banco
// (v_para_revisar, v_revisadas, casar_transacoes_bancarias).

type Candidato = {
  tipo: 'avulso' | 'parcelamento' | 'recorrente' | 'liquidacao';
  id?: string;
  ciclo?: string;
  descricao?: string;
  valor?: number;
  data?: string;
};

type ItemRevisar = {
  id: string;
  data: string;
  valor: number;
  sentido: 'receita' | 'despesa';
  descricao: string;
  tipo_conta: 'BANK' | 'CREDIT';
  tipo_operacao: string | null;
  meio_inferido: string | null;
  parcela_numero: number | null;
  parcela_total: number | null;
  transferencia_propria: boolean;
  candidatos: Candidato[];
  categoria_sugerida_id: string | null;
  banco: string | null;
  conta_no_saldo: boolean;
};

type ItemRevisado = {
  id: string;
  data: string;
  valor: number;
  sentido: 'receita' | 'despesa';
  descricao: string;
  estado: 'confirmada' | 'ignorada' | 'vinculada';
  vinculo_tipo: string | null;
  vinculo_automatico: boolean;
  removida_em: string | null;
  banco: string | null;
  vinculado_a: string | null;
};

type Categoria = { id: string; nome: string; tipo: 'receita' | 'despesa' };

type Filtro = 'todas' | 'no_saldo' | 'fora' | 'sugestao' | 'parceladas' | 'revisadas';

// Parcelada vinda do banco (ESPECIFICACAO.md 14.21): nunca conta no saldo por
// aqui -- a fonte e o parcelamento cadastrado a mao. O filtro so serve para
// conferir que a compra ja foi lancada e que o valor bate.
type ItemParcelado = {
  id: string;
  data: string;
  valor: number;
  descricao: string;
  parcela_numero: number | null;
  parcela_total: number | null;
  banco: string | null;
  parcelamento_descricao: string | null;
  parcelamento_valor: number | null;
  parcelamento_total: number | null;
  situacao: 'confere' | 'sem_cadastro' | 'ignorada';
  candidatos: Candidato[];
};

const FILTROS: { id: Filtro; rotulo: string }[] = [
  { id: 'todas', rotulo: 'Todas' },
  { id: 'no_saldo', rotulo: 'Contam no saldo' },
  { id: 'fora', rotulo: 'Fora do saldo' },
  { id: 'sugestao', rotulo: 'Com sugestao' },
  { id: 'parceladas', rotulo: 'Parceladas' },
  { id: 'revisadas', rotulo: 'Revisadas' },
];

const ROTULO_VINCULO: Record<string, string> = {
  avulso: 'lancamento',
  parcelamento: 'parcelamento',
  execucao: 'recorrente',
  liquidacao: 'pagamento de fatura',
  interna: 'transferencia entre suas contas',
};

function deslocarMeses(ciclo: string, meses: number): string {
  const d = new Date(`${ciclo}T00:00:00`);
  d.setMonth(d.getMonth() + meses);
  return d.toISOString().slice(0, 10);
}

const escapar = (s: string) =>
  s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);

const sinal = (sentido: string) => (sentido === 'receita' ? '+' : '-');

export async function renderRevisar(page: HTMLElement): Promise<void> {
  page.innerHTML = `<p>Carregando...</p>`;
  const { data: cicloAtual, error } = await supabase.rpc('ciclo', { d: todayISO() });
  if (error || !cicloAtual) {
    page.innerHTML = `<p class="msg erro">Erro ao calcular o ciclo atual: ${error?.message ?? ''}</p>`;
    return;
  }
  await renderCiclo(page, cicloAtual, 'todas');
}

async function renderCiclo(page: HTMLElement, ciclo: string, filtro: Filtro): Promise<void> {
  page.innerHTML = `<p>Carregando...</p>`;

  const [resumoRes, itensRes, revisadasRes, categoriasRes, periodo, parceladasRes] = await Promise.all([
    supabase.from('v_resumo_banco').select('itens_para_revisar, valor_provisorio_no_saldo, valor_fora_do_saldo, saidas_proprias_sem_par').maybeSingle(),
    supabase
      .from('v_para_revisar')
      .select('id, data, valor, sentido, descricao, tipo_conta, tipo_operacao, meio_inferido, parcela_numero, parcela_total, transferencia_propria, candidatos, categoria_sugerida_id, banco, conta_no_saldo')
      .eq('ciclo', ciclo)
      .order('data')
      .order('descricao'),
    filtro === 'revisadas'
      ? supabase
          .from('v_revisadas')
          .select('id, data, valor, sentido, descricao, estado, vinculo_tipo, vinculo_automatico, removida_em, banco, vinculado_a')
          .eq('ciclo', ciclo)
          .order('data')
      : Promise.resolve({ data: [], error: null }),
    supabase.from('categorias').select('id, nome, tipo').eq('ativa', true).order('nome'),
    periodoDoCiclo(ciclo),
    supabase
      .from('v_parceladas_banco')
      .select('id, data, valor, descricao, parcela_numero, parcela_total, banco, parcelamento_descricao, parcelamento_valor, parcelamento_total, situacao, candidatos')
      .eq('ciclo', ciclo)
      .order('situacao', { ascending: false })
      .order('data'),
  ]);

  if (resumoRes.error || itensRes.error || revisadasRes.error || categoriasRes.error || parceladasRes.error) {
    const msg = resumoRes.error?.message ?? itensRes.error?.message ?? revisadasRes.error?.message
      ?? categoriasRes.error?.message ?? parceladasRes.error?.message;
    page.innerHTML = `<p class="msg erro">Erro ao carregar: ${msg}</p>`;
    return;
  }

  const resumo = resumoRes.data as {
    itens_para_revisar: number;
    valor_provisorio_no_saldo: number;
    valor_fora_do_saldo: number;
    saidas_proprias_sem_par: number;
  } | null;
  const todos = (itensRes.data ?? []) as ItemRevisar[];
  const categorias = (categoriasRes.data ?? []) as Categoria[];
  const parceladas = (parceladasRes.data ?? []) as ItemParcelado[];
  const semCadastro = parceladas.filter((p) => p.situacao === 'sem_cadastro').length;
  const saidasProprias = resumo?.saidas_proprias_sem_par ?? 0;
  const itens = todos.filter((i) =>
    filtro === 'todas' ? true
    : filtro === 'no_saldo' ? i.conta_no_saldo
    : filtro === 'fora' ? !i.conta_no_saldo && i.candidatos.length === 0
    : filtro === 'sugestao' ? i.candidatos.length > 0
    : false,
  );

  page.innerHTML = `
    <div class="nav-mes">
      <button type="button" id="btn-mes-anterior">&lsaquo;</button>
      <h1>${rotuloCiclo(ciclo)}</h1>
      <button type="button" id="btn-mes-seguinte">&rsaquo;</button>
    </div>
    ${periodo ? `<p class="periodo">${rotuloPeriodo(periodo.inicio, periodo.fim)}</p>` : ''}

    <section class="cartao resumo-revisar">
      <p><strong>${resumo?.itens_para_revisar ?? 0}</strong> para revisar (todos os meses)</p>
      <p>Ja no saldo, provisorio: ${formatBRL(resumo?.valor_provisorio_no_saldo ?? 0)}</p>
      <p>Fora do saldo ate confirmar: ${formatBRL(resumo?.valor_fora_do_saldo ?? 0)}</p>
    </section>

    <div class="filtros">
      ${FILTROS.map((f) => `<button type="button" class="chip ${f.id === filtro ? 'ativo' : ''}" data-filtro="${f.id}">${f.rotulo}${
        f.id === 'revisadas' ? ''
          : f.id === 'parceladas' ? ` (${semCadastro} sem cadastro)`
          : ` (${contar(todos, f.id)})`
      }</button>`).join('')}
    </div>

    ${
      filtro !== 'revisadas' && filtro !== 'parceladas' && saidasProprias > 0
        ? `<div class="acao-lote">
            <button type="button" class="btn-secundario" id="btn-ignorar-proprias">
              Ignorar transferencias para mim sem par (${saidasProprias})
            </button>
            <p class="msg">Saidas do seu CPF para conta nao conectada (todos os meses). Cada uma fica em
              Revisadas, com Desfazer.</p>
          </div>`
        : ''
    }
    ${
      filtro === 'revisadas'
        ? renderRevisadas((revisadasRes.data ?? []) as ItemRevisado[])
        : filtro === 'parceladas'
        ? renderParceladas(parceladas)
        : itens.length === 0
          ? '<p class="msg">Nada para revisar neste filtro e ciclo.</p>'
          : `<ul class="lista-ciclo lista-revisar">${itens.map((i) => renderItem(i, categorias)).join('')}</ul>`
    }
  `;

  page.querySelector('#btn-mes-anterior')!.addEventListener('click', () => void renderCiclo(page, deslocarMeses(ciclo, -1), filtro));
  page.querySelector('#btn-mes-seguinte')!.addEventListener('click', () => void renderCiclo(page, deslocarMeses(ciclo, 1), filtro));
  page.querySelectorAll<HTMLButtonElement>('.chip').forEach((b) =>
    b.addEventListener('click', () => void renderCiclo(page, ciclo, b.dataset.filtro as Filtro)),
  );

  const recarregar = () => renderCiclo(page, ciclo, filtro);
  wireItens(page, recarregar);

  page.querySelector<HTMLButtonElement>('#btn-ignorar-proprias')?.addEventListener('click', async (e) => {
    const botao = e.currentTarget as HTMLButtonElement;
    botao.disabled = true;
    const { error: erro } = await supabase.rpc('ignorar_transferencias_proprias');
    if (erro) {
      botao.disabled = false;
      botao.insertAdjacentHTML('afterend', `<p class="msg erro">Erro: ${escapar(erro.message)}</p>`);
      return;
    }
    await recarregar();
  });
}

function contar(itens: ItemRevisar[], f: Filtro): number {
  return itens.filter((i) =>
    f === 'todas' ? true
    : f === 'no_saldo' ? i.conta_no_saldo
    : f === 'fora' ? !i.conta_no_saldo && i.candidatos.length === 0
    : f === 'sugestao' ? i.candidatos.length > 0
    : false,
  ).length;
}

function rotuloSituacao(i: ItemRevisar): string {
  if (i.candidatos.length > 0) return '<span class="selo selo-sugestao">sugestao</span>';
  // Entrada do proprio CPF que sobrou sem par: veio de conta nao conectada (ex. BB).
  if (i.conta_no_saldo && i.transferencia_propria) {
    return '<span class="selo selo-saldo">de conta sua nao conectada -- ja conta</span>';
  }
  if (i.conta_no_saldo) return '<span class="selo selo-saldo">ja conta no saldo</span>';
  if (i.transferencia_propria) return '<span class="selo">para conta sua nao conectada?</span>';
  return '<span class="selo">fora do saldo</span>';
}

function renderItem(i: ItemRevisar, categorias: Categoria[]): string {
  const opcoes = categorias
    .filter((c) => c.tipo === i.sentido)
    .map((c) => `<option value="${c.id}" ${c.id === i.categoria_sugerida_id ? 'selected' : ''}>${escapar(c.nome)}</option>`)
    .join('');
  const meta = [
    formatData(i.data),
    i.banco,
    i.tipo_conta === 'CREDIT' ? 'Cartao' : rotuloMeio(i.meio_inferido),
    i.parcela_total && i.parcela_total > 1 ? `parcela ${i.parcela_numero}/${i.parcela_total}` : null,
  ].filter(Boolean).join(' · ');

  return `
    <li data-id="${i.id}">
      <div class="linha-topo">
        <span>${escapar(i.descricao)}</span>
        <span class="valor-${i.sentido}">${sinal(i.sentido)} ${formatBRL(i.valor)}</span>
      </div>
      <p class="linha-meta">${escapar(meta)} ${rotuloSituacao(i)}</p>
      ${
        i.candidatos.length > 0
          ? `<div class="candidatos">
              <p class="msg">E um destes?</p>
              ${i.candidatos.map((c, n) => `
                <div class="candidato">
                  <span>${escapar(rotuloCandidato(c))}</span>
                  <button type="button" class="btn-secundario btn-vincular" data-n="${n}">Vincular</button>
                </div>`).join('')}
            </div>`
          : ''
      }
      <div class="linha-controles">
        <select class="categoria-revisar" aria-label="Categoria">
          <option value="" ${i.categoria_sugerida_id ? '' : 'selected'} disabled>Categoria...</option>
          ${opcoes}
        </select>
        <button type="button" class="btn-confirmar">Confirmar</button>
        <button type="button" class="btn-secundario btn-ignorar">Ignorar</button>
      </div>
      <p class="msg msg-linha" hidden></p>
      <script type="application/json" class="dados-candidatos">${JSON.stringify(i.candidatos).replace(/</g, '\\u003c')}</script>
    </li>`;
}

function rotuloCandidato(c: Candidato): string {
  if (c.tipo === 'liquidacao') return 'Pagamento de fatura do cartao';
  const tipo = c.tipo === 'avulso' ? 'Lancamento' : c.tipo === 'parcelamento' ? 'Parcelamento' : 'Recorrente';
  return [
    `${tipo}: ${c.descricao ?? ''}`,
    c.valor != null ? formatBRL(c.valor) : null,
    c.data ? formatData(c.data) : c.ciclo ? rotuloCiclo(c.ciclo) : null,
  ].filter(Boolean).join(' · ');
}

function renderParceladas(itens: ItemParcelado[]): string {
  if (itens.length === 0) return '<p class="msg">Nenhuma parcela do banco neste ciclo.</p>';
  return `
    <p class="msg">Parcelas que o banco mostrou. Nao contam no saldo por aqui: quem conta e o
      parcelamento que voce cadastrou. Use esta lista so para conferir.</p>
    <ul class="lista-ciclo lista-revisar">
      ${itens.map((i) => {
        const parcela = i.parcela_total ? `parcela ${i.parcela_numero ?? '?'}/${i.parcela_total}` : 'parcelada';
        const situacao = i.situacao === 'confere'
          ? `<span class="selo selo-confere">confere com: ${escapar(i.parcelamento_descricao ?? '')}${
              i.parcelamento_valor != null ? ` (${formatBRL(i.parcelamento_valor)} x ${i.parcelamento_total})` : ''
            }</span>`
          : i.situacao === 'ignorada'
            ? '<span class="selo">ignorada</span>'
            : '<span class="selo selo-saldo">sem parcelamento cadastrado</span>';
        return `
          <li data-id="${i.id}">
            <div class="linha-topo">
              <span>${escapar(i.descricao)}</span>
              <span class="valor-despesa">- ${formatBRL(i.valor)}</span>
            </div>
            <p class="linha-meta">${escapar([formatData(i.data), i.banco, parcela].filter(Boolean).join(' · '))} ${situacao}</p>
            ${
              i.situacao === 'sem_cadastro'
                ? `${
                    i.candidatos.length > 0
                      ? `<div class="candidatos">
                          <p class="msg">E um destes parcelamentos?</p>
                          ${i.candidatos.map((c, n) => `
                            <div class="candidato">
                              <span>${escapar(rotuloCandidato(c))}</span>
                              <button type="button" class="btn-secundario btn-vincular" data-n="${n}">Vincular</button>
                            </div>`).join('')}
                        </div>`
                      : '<p class="msg">Cadastre esta compra na aba Parcelar; na proxima sincronizacao ela passa a "confere".</p>'
                  }
                  <div class="linha-controles">
                    <button type="button" class="btn-secundario btn-ignorar">Ignorar</button>
                  </div>
                  <script type="application/json" class="dados-candidatos">${JSON.stringify(i.candidatos).replace(/</g, '\\u003c')}</script>`
                : i.situacao === 'ignorada'
                  ? `<div class="linha-controles"><button type="button" class="btn-secundario btn-desfazer">Desfazer</button></div>`
                  : ''
            }
            <p class="msg msg-linha" hidden></p>
          </li>`;
      }).join('')}
    </ul>`;
}

function renderRevisadas(itens: ItemRevisado[]): string {
  if (itens.length === 0) return '<p class="msg">Nada revisado neste ciclo.</p>';
  return `
    <ul class="lista-ciclo lista-revisar">
      ${itens.map((i) => {
        const como = i.estado === 'ignorada' ? 'Ignorada'
          : i.estado === 'confirmada' ? 'Confirmada como lancamento'
          : `${i.vinculo_automatico ? 'Vinculada automaticamente' : 'Vinculada'} a ${ROTULO_VINCULO[i.vinculo_tipo ?? ''] ?? ''}${i.vinculado_a ? `: ${i.vinculado_a}` : ''}`;
        return `
          <li data-id="${i.id}">
            <div class="linha-topo">
              <span>${escapar(i.descricao)}</span>
              <span class="valor-${i.sentido}">${sinal(i.sentido)} ${formatBRL(i.valor)}</span>
            </div>
            <p class="linha-meta">${escapar([formatData(i.data), i.banco, como].filter(Boolean).join(' · '))}${
              i.removida_em ? ' <span class="selo selo-sugestao">o banco removeu esta transacao</span>' : ''
            }</p>
            <div class="linha-controles">
              <button type="button" class="btn-secundario btn-desfazer">Desfazer</button>
            </div>
            <p class="msg msg-linha" hidden></p>
          </li>`;
      }).join('')}
    </ul>`;
}

function wireItens(page: HTMLElement, recarregar: () => Promise<void>): void {
  page.querySelectorAll<HTMLLIElement>('.lista-revisar li').forEach((li) => {
    const id = li.dataset.id!;
    const msg = li.querySelector<HTMLParagraphElement>('.msg-linha')!;

    // Executa a acao; em sucesso recarrega (contadores e listas vem do banco).
    const acao = async (botao: HTMLButtonElement, chamada: () => PromiseLike<{ error: { message: string } | null }>) => {
      li.querySelectorAll('button').forEach((b) => (b.disabled = true));
      const { error } = await chamada();
      if (error) {
        msg.hidden = false;
        msg.textContent = `Erro: ${error.message}`;
        msg.className = 'msg erro msg-linha';
        li.querySelectorAll('button').forEach((b) => (b.disabled = false));
        return;
      }
      botao.textContent = 'Feito';
      await recarregar();
    };

    li.querySelector<HTMLButtonElement>('.btn-confirmar')?.addEventListener('click', (e) => {
      const categoria = li.querySelector<HTMLSelectElement>('.categoria-revisar')!.value;
      if (!categoria) {
        msg.hidden = false;
        msg.textContent = 'Escolha a categoria antes de confirmar.';
        msg.className = 'msg erro msg-linha';
        return;
      }
      void acao(e.currentTarget as HTMLButtonElement, () =>
        supabase.rpc('confirmar_transacao', { p_id: id, p_categoria: categoria }));
    });

    li.querySelector<HTMLButtonElement>('.btn-ignorar')?.addEventListener('click', (e) =>
      void acao(e.currentTarget as HTMLButtonElement, () => supabase.rpc('ignorar_transacao', { p_id: id })));

    li.querySelector<HTMLButtonElement>('.btn-desfazer')?.addEventListener('click', (e) =>
      void acao(e.currentTarget as HTMLButtonElement, () => supabase.rpc('desfazer_transacao', { p_id: id })));

    const candidatos = JSON.parse(li.querySelector('.dados-candidatos')?.textContent ?? '[]') as Candidato[];
    li.querySelectorAll<HTMLButtonElement>('.btn-vincular').forEach((b) =>
      b.addEventListener('click', () => {
        const c = candidatos[Number(b.dataset.n)];
        void acao(b, () =>
          supabase.rpc('vincular_transacao', {
            p_id: id,
            p_tipo: c.tipo,
            p_alvo: c.id ?? null,
            p_ciclo: c.ciclo ?? null,
          }));
      }),
    );
  });
}
