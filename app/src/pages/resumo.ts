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

export async function renderResumo(page: HTMLElement): Promise<void> {
  page.innerHTML = `<p>Carregando resumo...</p>`;

  const { data: cicloAtual, error: cicloError } = await supabase.rpc('ciclo', { d: todayISO() });
  if (cicloError || !cicloAtual) {
    page.innerHTML = `<p class="msg erro">Erro ao calcular o ciclo atual: ${cicloError?.message ?? ''}</p>`;
    return;
  }

  const [resumoRes, previsaoRes, alertasRes] = await Promise.all([
    supabase.from('v_resumo_ciclo').select('*').eq('ciclo', cicloAtual).maybeSingle(),
    supabase.from('v_previsao').select('ciclo, saldo_projetado').order('ciclo'),
    supabase.from('v_alertas').select('ciclo, saldo_projetado').order('ciclo'),
  ]);

  if (resumoRes.error || previsaoRes.error || alertasRes.error) {
    page.innerHTML = `<p class="msg erro">Erro ao carregar o resumo.</p>`;
    return;
  }

  const resumo = resumoRes.data as ResumoCiclo | null;
  const previsao = (previsaoRes.data ?? []) as PrevisaoLinha[];
  const alertas = (alertasRes.data ?? []) as PrevisaoLinha[];

  page.innerHTML = `
    <h1>Resumo — ${rotuloCiclo(cicloAtual)}</h1>

    ${
      alertas.length > 0
        ? `<div class="alerta">
            ${alertas.map((a) => `<p>Saldo negativo previsto em ${rotuloCiclo(a.ciclo)}: ${formatBRL(a.saldo_projetado)}</p>`).join('')}
          </div>`
        : ''
    }

    <section class="cartao">
      <p>Receitas: ${formatBRL(resumo?.receitas)}</p>
      <p>Despesas: ${formatBRL(resumo?.despesas)}</p>
      <p><strong>Saldo do ciclo: ${formatBRL(resumo?.saldo)}</strong></p>
      <p>Realizado: ${formatBRL((resumo?.receitas_realizadas ?? 0) - (resumo?.despesas_realizadas ?? 0))}</p>
      <p>Previsto: ${formatBRL((resumo?.receitas_previstas ?? 0) - (resumo?.despesas_previstas ?? 0))}</p>
    </section>

    <h2>Previsao do horizonte</h2>
    ${
      previsao.length === 0
        ? '<p>Sem previsao ainda -- registre um saldo apurado em Configuracao para comecar a projetar.</p>'
        : `<ul>${previsao.map((p) => `<li>${rotuloCiclo(p.ciclo)}: ${formatBRL(p.saldo_projetado)}</li>`).join('')}</ul>`
    }
  `;
}
