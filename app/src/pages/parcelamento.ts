import { supabase } from '../lib/supabaseClient';
import { formatBRL, todayISO } from '../lib/format';

type Categoria = { id: string; nome: string };

const MEIOS = ['credito', 'debito', 'pix', 'dinheiro', 'boleto', 'folha'] as const;

export async function renderParcelamento(page: HTMLElement): Promise<void> {
  page.innerHTML = `<p>Carregando categorias...</p>`;

  const { data: categorias, error } = await supabase
    .from('categorias')
    .select('id, nome')
    .eq('tipo', 'despesa')
    .eq('ativa', true)
    .order('nome');

  if (error) {
    page.innerHTML = `<p class="msg erro">Erro ao carregar categorias: ${error.message}</p>`;
    return;
  }

  page.innerHTML = `
    <h1>Novo parcelamento</h1>
    <form id="form-parcelamento" class="form">
      <label>Descricao<input type="text" name="descricao" required></label>
      <label>Categoria
        <select name="categoria_id" required>
          ${(categorias ?? []).map((c: Categoria) => `<option value="${c.id}">${c.nome}</option>`).join('')}
        </select>
      </label>
      <label>Meio de pagamento
        <select name="meio_pagamento" required>
          ${MEIOS.map((m) => `<option value="${m}">${m}</option>`).join('')}
        </select>
      </label>
      <label>Data da compra<input type="date" name="data_compra" value="${todayISO()}" required></label>
      <label>Valor da parcela<input type="number" name="valor_parcela" step="0.01" min="0.01" required></label>
      <label>Quantidade de parcelas<input type="number" name="num_parcelas" min="1" step="1" required></label>
      <button type="button" id="btn-projetar">Ver projecao</button>
      <div id="projecao"></div>
      <button type="submit" id="btn-salvar" disabled>Salvar</button>
      <p class="msg" id="msg" hidden></p>
    </form>
  `;

  const form = page.querySelector<HTMLFormElement>('#form-parcelamento')!;
  const projecaoEl = page.querySelector<HTMLDivElement>('#projecao')!;
  const btnSalvar = page.querySelector<HTMLButtonElement>('#btn-salvar')!;
  const msg = page.querySelector<HTMLParagraphElement>('#msg')!;

  // A regra de competencia (ciclo_caixa) roda so no banco. Aqui apenas
  // deslocamos o ciclo-base, mes a mes, para montar a lista de parcelas --
  // a mesma formula usada pela view v_parcelas.
  page.querySelector('#btn-projetar')!.addEventListener('click', async () => {
    const dados = new FormData(form);
    const dataCompra = String(dados.get('data_compra') ?? '');
    const meio = String(dados.get('meio_pagamento') ?? '');
    const valorParcela = Number(dados.get('valor_parcela'));
    const numParcelas = Number(dados.get('num_parcelas'));

    if (!dataCompra || !meio || !valorParcela || !numParcelas) {
      projecaoEl.innerHTML = `<p class="msg erro">Preencha data, meio, valor e quantidade antes de projetar.</p>`;
      btnSalvar.disabled = true;
      return;
    }

    const { data: cicloBase, error: rpcError } = await supabase.rpc('ciclo_caixa', {
      d: dataCompra,
      meio,
    });

    if (rpcError || !cicloBase) {
      projecaoEl.innerHTML = `<p class="msg erro">Erro ao calcular projecao: ${rpcError?.message ?? ''}</p>`;
      btnSalvar.disabled = true;
      return;
    }

    const base = new Date(`${cicloBase}T00:00:00`);
    const linhas = Array.from({ length: numParcelas }, (_, i) => {
      const ciclo = new Date(base);
      ciclo.setMonth(ciclo.getMonth() + i);
      const rotulo = ciclo.toLocaleDateString('pt-BR', { month: 'long', year: 'numeric' });
      return `<li>${i + 1}/${numParcelas} — ${rotulo} — ${formatBRL(valorParcela)}</li>`;
    });

    projecaoEl.innerHTML = `
      <p>Total: ${formatBRL(valorParcela * numParcelas)}</p>
      <ul>${linhas.join('')}</ul>
    `;
    btnSalvar.disabled = false;
  });

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const dados = new FormData(form);

    const { error: insertError } = await supabase.from('parcelamentos').insert({
      descricao: String(dados.get('descricao')),
      categoria_id: String(dados.get('categoria_id')),
      meio_pagamento: String(dados.get('meio_pagamento')),
      data_compra: String(dados.get('data_compra')),
      valor_parcela: Number(dados.get('valor_parcela')),
      num_parcelas: Number(dados.get('num_parcelas')),
    });

    msg.hidden = false;
    if (insertError) {
      msg.textContent = `Erro: ${insertError.message}`;
      msg.className = 'msg erro';
    } else {
      msg.textContent = 'Parcelamento salvo.';
      msg.className = 'msg sucesso';
      form.reset();
      projecaoEl.innerHTML = '';
      btnSalvar.disabled = true;
    }
  });
}
