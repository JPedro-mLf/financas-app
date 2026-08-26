import { supabase } from '../lib/supabaseClient';
import { todayISO } from '../lib/format';

type Categoria = { id: string; nome: string; tipo: 'receita' | 'despesa' };

const MEIOS = ['pix', 'debito', 'dinheiro', 'boleto', 'credito', 'folha'] as const;

export async function renderLancamentoRapido(page: HTMLElement): Promise<void> {
  page.innerHTML = `<p>Carregando categorias...</p>`;

  const { data: categorias, error } = await supabase
    .from('categorias')
    .select('id, nome, tipo')
    .eq('ativa', true)
    .order('nome');

  if (error) {
    page.innerHTML = `<p class="msg erro">Erro ao carregar categorias: ${error.message}</p>`;
    return;
  }

  if (!categorias || categorias.length === 0) {
    page.innerHTML = `<p>Nenhuma categoria cadastrada ainda. Cadastre pelo menos uma em Configuracao.</p>`;
    return;
  }

  page.innerHTML = `
    <h1>Lancamento rapido</h1>
    <form id="form-avulso" class="form">
      <label>Valor
        <input type="number" name="valor" inputmode="decimal" step="0.01" min="0.01" required autofocus>
      </label>
      <label>Descricao
        <input type="text" name="descricao" required>
      </label>
      <label>Categoria
        <select name="categoria_id" required>
          ${categorias.map((c: Categoria) => `<option value="${c.id}">${c.nome} (${c.tipo})</option>`).join('')}
        </select>
      </label>
      <label>Meio de pagamento
        <select name="meio_pagamento" required>
          ${MEIOS.map((m) => `<option value="${m}">${m}</option>`).join('')}
        </select>
      </label>
      <label>Data
        <input type="date" name="data" value="${todayISO()}" required>
      </label>
      <button type="submit">Salvar</button>
      <p class="msg" id="msg" hidden></p>
    </form>
  `;

  const tipoPorCategoria = new Map(categorias.map((c: Categoria) => [c.id, c.tipo]));
  const form = page.querySelector<HTMLFormElement>('#form-avulso')!;
  const msg = page.querySelector<HTMLParagraphElement>('#msg')!;
  const inputData = form.elements.namedItem('data') as HTMLInputElement;

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const dados = new FormData(form);
    const categoriaId = String(dados.get('categoria_id'));
    const tipo = tipoPorCategoria.get(categoriaId);

    const { error: insertError } = await supabase.from('avulsos').insert({
      valor: Number(dados.get('valor')),
      descricao: String(dados.get('descricao')),
      categoria_id: categoriaId,
      tipo,
      meio_pagamento: String(dados.get('meio_pagamento')),
      data: String(dados.get('data')),
    });

    msg.hidden = false;
    if (insertError) {
      msg.textContent = `Erro: ${insertError.message}`;
      msg.className = 'msg erro';
    } else {
      msg.textContent = 'Lancamento salvo.';
      msg.className = 'msg sucesso';
      form.reset();
      inputData.value = todayISO();
    }
  });
}
