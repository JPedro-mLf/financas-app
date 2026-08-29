import { supabase } from '../lib/supabaseClient';
import { formatBRL, rotuloCiclo, todayISO } from '../lib/format';

type ResumoCiclo = {
  receitas: number;
  despesas: number;
  saldo: number;
  receitas_realizadas: number;
  receitas_previstas: number;
  despesas_realizadas: number;
  despesas_previstas: number;
};

type PrevisaoLinha = { ciclo: string; saldo_projetado: number };
type ReservaLinha = { descricao: string; reserva_acumulada: number };
type CategoriaLinha = { categoria_nome: string; total: number };

// Ordem fixa (nao ciclar): paleta categorica validada p/ modo escuro contra
// a superficie do app (ver ESPECIFICACAO.md -- skill de dataviz).
const CORES_CATEGORIA = ['#d95926', '#199e70', '#c98500', '#d55181', '#9085e9'];
const COR_OUTRAS = '#6b7280';
const MAX_CATEGORIAS_VISIVEIS = 5;

function deslocarMeses(ciclo: string, meses: number): string {
  const d = new Date(`${ciclo}T00:00:00`);
  d.setMonth(d.getMonth() + meses);
  return d.toISOString().slice(0, 10);
}

export async function renderResumo(page: HTMLElement): Promise<void> {
  page.innerHTML = `<p>Carregando resumo...</p>`;

  const { data: cicloAtual, error: cicloError } = await supabase.rpc('ciclo', { d: todayISO() });
  if (cicloError || !cicloAtual) {
    page.innerHTML = `<p class="msg erro">Erro ao calcular o ciclo atual: ${cicloError?.message ?? ''}</p>`;
    return;
  }

  // Previsao, alertas e reservas nao mudam com a navegacao entre meses --
  // sao projecoes/acumulados a partir do historico inteiro, nao do ciclo
  // que esta sendo visualizado. So o card do ciclo (e o saldo acumulado
  // dentro dele) mudam.
  const [previsaoRes, alertasRes, reservasRes] = await Promise.all([
    supabase.from('v_previsao').select('ciclo, saldo_projetado').order('ciclo'),
    supabase.from('v_alertas').select('ciclo, saldo_projetado').order('ciclo'),
    supabase.from('v_reserva_estimados').select('descricao, reserva_acumulada').order('descricao'),
  ]);

  if (previsaoRes.error || alertasRes.error || reservasRes.error) {
    page.innerHTML = `<p class="msg erro">Erro ao carregar o resumo.</p>`;
    return;
  }

  const previsao = (previsaoRes.data ?? []) as PrevisaoLinha[];
  const alertas = (alertasRes.data ?? []) as PrevisaoLinha[];
  const reservas = (reservasRes.data ?? []) as ReservaLinha[];

  const painelFixo = `
    ${
      alertas.length > 0
        ? `<div class="alerta">
            ${alertas.map((a) => `<p>Saldo negativo previsto em ${rotuloCiclo(a.ciclo)}: ${formatBRL(a.saldo_projetado)}</p>`).join('')}
          </div>`
        : ''
    }
    <h2>Previsao do horizonte</h2>
    ${
      previsao.length === 0
        ? '<p>Sem previsao ainda -- registre um saldo apurado em Configuracao para comecar a projetar.</p>'
        : `<ul>${previsao.map((p) => `<li>${rotuloCiclo(p.ciclo)}: ${formatBRL(p.saldo_projetado)}</li>`).join('')}</ul>`
    }

    ${
      reservas.length > 0
        ? `<h2>Reservas dos itens estimados</h2>
           <p class="msg">Diferenca acumulada entre o previsto e o realizado nos ciclos ja
             confirmados -- gastou menos que o provisionado, guarda; gastou mais, consome.</p>
           <ul>${reservas.map((r) => `<li>${r.descricao}: ${formatBRL(r.reserva_acumulada)}</li>`).join('')}</ul>`
        : ''
    }
  `;

  await renderCiclo(page, cicloAtual, cicloAtual, painelFixo);
}

async function renderCiclo(page: HTMLElement, ciclo: string, cicloAtual: string, painelFixo: string): Promise<void> {
  page.innerHTML = `<p>Carregando resumo...</p>`;

  const [resumoRes, acumuladoRes, categoriasRes] = await Promise.all([
    supabase.from('v_resumo_ciclo').select('*').eq('ciclo', ciclo).maybeSingle(),
    supabase.from('v_saldo_acumulado').select('saldo_acumulado').eq('ciclo', ciclo).maybeSingle(),
    supabase
      .from('v_gastos_por_categoria')
      .select('categoria_nome, total')
      .eq('ciclo', ciclo)
      .eq('tipo', 'despesa')
      .order('total', { ascending: false }),
  ]);

  if (resumoRes.error || acumuladoRes.error || categoriasRes.error) {
    page.innerHTML = `<p class="msg erro">Erro ao carregar o resumo.</p>`;
    return;
  }

  const resumoTipado = resumoRes.data as ResumoCiclo | null;
  const saldoAcumulado = (acumuladoRes.data as { saldo_acumulado: number } | null)?.saldo_acumulado;
  const categorias = (categoriasRes.data ?? []) as CategoriaLinha[];

  page.innerHTML = `
    <div class="nav-mes">
      <button type="button" id="btn-mes-anterior">&lsaquo;</button>
      <h1>Resumo — ${rotuloCiclo(ciclo)}</h1>
      <button type="button" id="btn-mes-seguinte">&rsaquo;</button>
    </div>
    ${ciclo === cicloAtual ? '' : '<p class="msg">Ciclo atual: ' + rotuloCiclo(cicloAtual) + '</p>'}

    <section class="cartao">
      <p>Receitas: ${formatBRL(resumoTipado?.receitas)}</p>
      <p>Despesas: ${formatBRL(resumoTipado?.despesas)}</p>
      <p><strong>Saldo do ciclo (so este mes): ${formatBRL(resumoTipado?.saldo)}</strong></p>
      <p>Realizado: ${formatBRL((resumoTipado?.receitas_realizadas ?? 0) - (resumoTipado?.despesas_realizadas ?? 0))}</p>
      <p>Previsto: ${formatBRL((resumoTipado?.receitas_previstas ?? 0) - (resumoTipado?.despesas_previstas ?? 0))}</p>
      ${
        saldoAcumulado != null
          ? `<p class="acumulado"><strong>Saldo acumulado ate aqui: ${formatBRL(saldoAcumulado)}</strong></p>`
          : '<p class="msg">Sem saldo acumulado -- registre um saldo apurado em Configuracao.</p>'
      }
    </section>

    <section class="cartao">
      <h2>Gastos por categoria</h2>
      ${categorias.length === 0 ? '<p class="msg">Nenhuma despesa neste ciclo.</p>' : renderRankingCategorias(categorias)}
    </section>

    ${painelFixo}
  `;

  page.querySelector('#btn-mes-anterior')!.addEventListener('click', () => {
    void renderCiclo(page, deslocarMeses(ciclo, -1), cicloAtual, painelFixo);
  });
  page.querySelector('#btn-mes-seguinte')!.addEventListener('click', () => {
    void renderCiclo(page, deslocarMeses(ciclo, 1), cicloAtual, painelFixo);
  });
}

function renderRankingCategorias(categorias: CategoriaLinha[]): string {
  const visiveis = categorias.slice(0, MAX_CATEGORIAS_VISIVEIS);
  const resto = categorias.slice(MAX_CATEGORIAS_VISIVEIS);
  const linhas = [...visiveis];
  if (resto.length > 0) {
    linhas.push({ categoria_nome: 'Outras', total: resto.reduce((s, c) => s + c.total, 0) });
  }

  const max = Math.max(...linhas.map((l) => l.total));

  return `
    <div class="lista-ranking">
      ${linhas.map((l, i) => `
        <div class="linha-ranking">
          <span class="nome">${l.categoria_nome}</span>
          <div class="trilha-barra">
            <div class="barra-preenchida" style="width:${((l.total / max) * 100).toFixed(1)}%; background:${i < CORES_CATEGORIA.length ? CORES_CATEGORIA[i] : COR_OUTRAS}"></div>
          </div>
          <span class="valor">${formatBRL(l.total)}</span>
        </div>
      `).join('')}
    </div>
  `;
}
