import { supabase } from '../lib/supabaseClient';
import { formatBRL, rotuloCiclo, todayISO } from '../lib/format';

type LinhaCiclo = {
  origem_id: string;
  descricao: string;
  valor: number;
  status: 'previsto' | 'pendente' | 'pago' | 'cancelado';
  estimado: boolean;
};

export async function renderCicloAtual(page: HTMLElement): Promise<void> {
  page.innerHTML = `<p>Carregando ciclo atual...</p>`;

  const { data: cicloAtual, error: cicloError } = await supabase.rpc('ciclo', { d: todayISO() });
  if (cicloError || !cicloAtual) {
    page.innerHTML = `<p class="msg erro">Erro ao calcular o ciclo atual: ${cicloError?.message ?? ''}</p>`;
    return;
  }

  const { data: linhas, error } = await supabase
    .from('v_recorrentes_ciclo')
    .select('origem_id, descricao, valor, status, estimado')
    .eq('ciclo', cicloAtual)
    .order('descricao');

  if (error) {
    page.innerHTML = `<p class="msg erro">Erro ao carregar o ciclo: ${error.message}</p>`;
    return;
  }

  page.innerHTML = `
    <h1>Ciclo atual — ${rotuloCiclo(cicloAtual)}</h1>
    ${
      (linhas ?? []).length === 0
        ? '<p>Nenhum recorrente neste ciclo.</p>'
        : `<ul class="lista-ciclo">
            ${(linhas as LinhaCiclo[]).map((l) => `
              <li data-id="${l.origem_id}">
                <div class="linha-topo">
                  <span>${l.descricao}${l.estimado ? ' <small>(estimado)</small>' : ''}</span>
                  <span>${formatBRL(l.valor)}</span>
                </div>
                <div class="linha-controles">
                  <input type="number" step="0.01" class="valor-realizado" placeholder="Valor real" value="${l.valor}">
                  <select class="status">
                    <option value="previsto" ${l.status === 'previsto' ? 'selected' : ''}>Previsto</option>
                    <option value="pendente" ${l.status === 'pendente' ? 'selected' : ''}>Pendente</option>
                    <option value="pago" ${l.status === 'pago' ? 'selected' : ''}>Pago</option>
                    <option value="cancelado" ${l.status === 'cancelado' ? 'selected' : ''}>Cancelado</option>
                  </select>
                  <button class="btn-salvar-linha" type="button">Salvar</button>
                </div>
                <p class="msg msg-linha" hidden></p>
              </li>
            `).join('')}
          </ul>`
    }
  `;

  page.querySelectorAll<HTMLLIElement>('.lista-ciclo li').forEach((li) => {
    const recorrenteId = li.dataset.id!;
    const btn = li.querySelector<HTMLButtonElement>('.btn-salvar-linha')!;
    const statusSel = li.querySelector<HTMLSelectElement>('.status')!;
    const valorInput = li.querySelector<HTMLInputElement>('.valor-realizado');
    const msg = li.querySelector<HTMLParagraphElement>('.msg-linha')!;

    btn.addEventListener('click', async () => {
      const status = statusSel.value;
      const valorRealizado = valorInput?.value ? Number(valorInput.value) : null;

      const { error: upsertError } = await supabase.from('execucoes').upsert(
        {
          recorrente_id: recorrenteId,
          ciclo: cicloAtual,
          status,
          valor_realizado: valorRealizado,
          data_efetiva: status === 'pago' ? todayISO() : null,
        },
        { onConflict: 'user_id,ciclo,recorrente_id' },
      );

      msg.hidden = false;
      msg.textContent = upsertError ? `Erro: ${upsertError.message}` : 'Salvo.';
      msg.className = upsertError ? 'msg erro msg-linha' : 'msg sucesso msg-linha';
    });
  });
}
