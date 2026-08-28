import { supabase } from '../lib/supabaseClient';
import { formatBRL, rotuloCiclo, todayISO } from '../lib/format';

type LinhaFluxo = {
  origem_id: string;
  origem: 'avulso' | 'recorrente' | 'parcelamento';
  descricao: string;
  tipo: 'receita' | 'despesa';
  valor: number;
  status: 'previsto' | 'pendente' | 'pago' | 'cancelado' | null;
};

const ROTULO_STATUS: Record<string, string> = {
  previsto: 'Previsto',
  pendente: 'Pendente',
  pago: 'Pago',
  cancelado: 'Cancelado',
};

function deslocarMeses(ciclo: string, meses: number): string {
  const d = new Date(`${ciclo}T00:00:00`);
  d.setMonth(d.getMonth() + meses);
  return d.toISOString().slice(0, 10);
}

export async function renderTransacoes(page: HTMLElement): Promise<void> {
  page.innerHTML = `<p>Carregando transacoes...</p>`;

  const { data: cicloAtual, error: cicloError } = await supabase.rpc('ciclo', { d: todayISO() });
  if (cicloError || !cicloAtual) {
    page.innerHTML = `<p class="msg erro">Erro ao calcular o ciclo atual: ${cicloError?.message ?? ''}</p>`;
    return;
  }

  await renderCiclo(page, cicloAtual, false);
}

async function renderCiclo(page: HTMLElement, ciclo: string, resumido: boolean): Promise<void> {
  page.innerHTML = `<p>Carregando transacoes...</p>`;

  const { data: linhas, error } = await supabase
    .from('v_fluxo')
    .select('origem_id, origem, descricao, tipo, valor, status')
    .eq('ciclo', ciclo)
    .order('descricao');

  if (error) {
    page.innerHTML = `<p class="msg erro">Erro ao carregar transacoes: ${error.message}</p>`;
    return;
  }

  const linhasTipadas = (linhas ?? []) as LinhaFluxo[];

  page.innerHTML = `
    <div class="nav-mes">
      <button type="button" id="btn-mes-anterior">&lsaquo;</button>
      <h1>${rotuloCiclo(ciclo)}</h1>
      <button type="button" id="btn-mes-seguinte">&rsaquo;</button>
    </div>
    <button type="button" id="btn-alternar-modo" class="btn-link">
      ${resumido ? 'Ver detalhado (editar)' : 'Ver resumido'}
    </button>
    ${
      linhasTipadas.length === 0
        ? '<p>Nenhuma transacao neste ciclo.</p>'
        : resumido
          ? renderListaResumida(linhasTipadas)
          : renderListaDetalhada(linhasTipadas)
    }
  `;

  page.querySelector('#btn-mes-anterior')!.addEventListener('click', () => {
    void renderCiclo(page, deslocarMeses(ciclo, -1), resumido);
  });
  page.querySelector('#btn-mes-seguinte')!.addEventListener('click', () => {
    void renderCiclo(page, deslocarMeses(ciclo, 1), resumido);
  });
  page.querySelector('#btn-alternar-modo')!.addEventListener('click', () => {
    void renderCiclo(page, ciclo, !resumido);
  });

  if (!resumido) wireEdicao(page, ciclo);
}

function renderListaResumida(linhas: LinhaFluxo[]): string {
  return `
    <ul class="lista-resumida">
      ${linhas.map((l) => `
        <li>
          <span>${l.descricao}</span>
          <span class="valor-${l.tipo}">${l.tipo === 'receita' ? '+' : '-'} ${formatBRL(l.valor)}</span>
          ${l.status ? `<span class="status-badge status-${l.status}">${ROTULO_STATUS[l.status]}</span>` : ''}
        </li>
      `).join('')}
    </ul>
  `;
}

function renderListaDetalhada(linhas: LinhaFluxo[]): string {
  return `
    <ul class="lista-ciclo">
      ${linhas.map((l) => `
        <li data-id="${l.origem_id}" data-origem="${l.origem}">
          <div class="linha-topo">
            <span>${l.descricao}${l.origem === 'parcelamento' ? ' <small>(parcela)</small>' : ''}</span>
            <span>${l.tipo === 'receita' ? '+' : '-'} ${formatBRL(l.valor)}</span>
          </div>
          ${
            l.origem === 'parcelamento'
              ? '<p class="msg">Parcela de um parcelamento -- valor da serie inteira, so leitura. Ajuste em Supabase Studio se precisar.</p>'
              : `<div class="linha-controles">
                  <input type="number" step="0.01" class="valor-editar" value="${l.valor}">
                  ${
                    l.origem === 'recorrente'
                      ? `<select class="status-editar">
                          <option value="previsto" ${l.status === 'previsto' ? 'selected' : ''}>Previsto</option>
                          <option value="pendente" ${l.status === 'pendente' ? 'selected' : ''}>Pendente</option>
                          <option value="pago" ${l.status === 'pago' ? 'selected' : ''}>Pago</option>
                          <option value="cancelado" ${l.status === 'cancelado' ? 'selected' : ''}>Cancelado</option>
                        </select>`
                      : ''
                  }
                  <button type="button" class="btn-salvar-linha">Salvar</button>
                  ${l.origem === 'avulso' ? '<button type="button" class="btn-excluir-linha">Excluir</button>' : ''}
                </div>`
          }
          <p class="msg msg-linha" hidden></p>
        </li>
      `).join('')}
    </ul>
  `;
}

function wireEdicao(page: HTMLElement, ciclo: string): void {
  page.querySelectorAll<HTMLLIElement>('.lista-ciclo li').forEach((li) => {
    const origemId = li.dataset.id!;
    const origem = li.dataset.origem as LinhaFluxo['origem'];
    if (origem === 'parcelamento') return;

    const msg = li.querySelector<HTMLParagraphElement>('.msg-linha')!;
    const valorInput = li.querySelector<HTMLInputElement>('.valor-editar')!;
    const btnSalvar = li.querySelector<HTMLButtonElement>('.btn-salvar-linha')!;
    const btnExcluir = li.querySelector<HTMLButtonElement>('.btn-excluir-linha');

    btnSalvar.addEventListener('click', async () => {
      const novoValor = Number(valorInput.value);
      let saveError: string | undefined;

      if (origem === 'avulso') {
        const { error: updateError } = await supabase.from('avulsos').update({ valor: novoValor }).eq('id', origemId);
        saveError = updateError?.message;
      } else {
        const statusSel = li.querySelector<HTMLSelectElement>('.status-editar')!;
        const status = statusSel.value;
        const { error: upsertError } = await supabase.from('execucoes').upsert(
          {
            recorrente_id: origemId,
            ciclo,
            status,
            valor_realizado: novoValor,
            data_efetiva: status === 'pago' ? todayISO() : null,
          },
          { onConflict: 'user_id,ciclo,recorrente_id' },
        );
        saveError = upsertError?.message;
      }

      msg.hidden = false;
      msg.textContent = saveError ? `Erro: ${saveError}` : 'Salvo.';
      msg.className = saveError ? 'msg erro msg-linha' : 'msg sucesso msg-linha';
    });

    btnExcluir?.addEventListener('click', async () => {
      if (!confirm('Excluir este lancamento avulso?')) return;
      const { error: deleteError } = await supabase.from('avulsos').delete().eq('id', origemId);
      if (deleteError) {
        msg.hidden = false;
        msg.textContent = `Erro: ${deleteError.message}`;
        msg.className = 'msg erro msg-linha';
        return;
      }
      li.remove();
    });
  });
}
