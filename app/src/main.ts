import './style.css';
import { registerSW } from 'virtual:pwa-register';
import { supabase } from './lib/supabaseClient';
import { navigate, registerRoute, startRouter } from './router';
import { renderLogin } from './pages/login';
import { renderLancamentoRapido } from './pages/lancamento-rapido';
import { renderParcelamento } from './pages/parcelamento';
import { renderCicloAtual } from './pages/ciclo-atual';
import { renderResumo } from './pages/resumo';
import { renderConfiguracao } from './pages/configuracao';
import { renderTransacoes } from './pages/transacoes';
import { renderRevisar } from './pages/revisar';

// Build do projeto-copia (ESPECIFICACAO.md 14.18): faixa fixa em todas as
// telas, inclusive o login, para nunca confundir com o app de producao.
if (import.meta.env.VITE_AMBIENTE === 'v2') {
  document.body.insertAdjacentHTML('afterbegin', '<div class="faixa-ambiente">v2 · teste da integracao bancaria</div>');
}

// A aba Revisar (integracao bancaria, ESPECIFICACAO.md 14.11) so existe no build
// v2 por enquanto: a producao ainda nao tem as tabelas da integracao.
const EH_V2 = import.meta.env.VITE_AMBIENTE === 'v2';

const ABAS = [
  { path: '/', label: 'Lancar' },
  { path: '/parcelamento', label: 'Parcelar' },
  { path: '/ciclo', label: 'Ciclo' },
  { path: '/transacoes', label: 'Extrato' },
  ...(EH_V2 ? [{ path: '/revisar', label: 'Revisar' }] : []),
  { path: '/resumo', label: 'Resumo' },
  { path: '/config', label: 'Config' },
];

function shell(root: HTMLElement, ativa: string): HTMLElement {
  root.innerHTML = `
    <main id="page" class="page"></main>
    <nav class="tabbar">
      ${ABAS.map((a) => `<a href="#${a.path}" class="${a.path === ativa ? 'active' : ''}">${a.label}</a>`).join('')}
    </nav>
  `;
  return root.querySelector<HTMLElement>('#page')!;
}

function autenticada(path: string, render: (page: HTMLElement) => void | Promise<void>): void {
  registerRoute(path, async (root) => {
    const { data } = await supabase.auth.getSession();
    if (!data.session) {
      navigate('/login');
      return;
    }
    await render(shell(root, path));
  });
}

registerRoute('/login', (root) => renderLogin(root));
autenticada('/', renderLancamentoRapido);
autenticada('/parcelamento', renderParcelamento);
autenticada('/ciclo', renderCicloAtual);
autenticada('/transacoes', renderTransacoes);
autenticada('/resumo', renderResumo);
autenticada('/config', renderConfiguracao);
if (EH_V2) autenticada('/revisar', renderRevisar);

const appRoot = document.querySelector<HTMLDivElement>('#app')!;
startRouter(appRoot);

supabase.auth.onAuthStateChange((_event, session) => {
  if (!session && window.location.hash !== '#/login') {
    navigate('/login');
  }
});

// App instalado no celular fica vivo em segundo plano e nunca recarrega, entao
// nao veria deploys novos. Procura atualizacao sempre que volta a ficar
// visivel; com registerType 'autoUpdate', o registerSW recarrega a pagina
// sozinho quando o service worker novo assume.
registerSW({
  immediate: true,
  onRegisteredSW(_url, registro) {
    if (!registro) return;
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') void registro.update();
    });
  },
});
