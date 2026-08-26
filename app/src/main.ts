import './style.css';
import { supabase } from './lib/supabaseClient';
import { navigate, registerRoute, startRouter } from './router';
import { renderLogin } from './pages/login';
import { renderLancamentoRapido } from './pages/lancamento-rapido';
import { renderParcelamento } from './pages/parcelamento';
import { renderCicloAtual } from './pages/ciclo-atual';
import { renderResumo } from './pages/resumo';
import { renderConfiguracao } from './pages/configuracao';

const ABAS = [
  { path: '/', label: 'Lancar' },
  { path: '/parcelamento', label: 'Parcelar' },
  { path: '/ciclo', label: 'Ciclo' },
  { path: '/resumo', label: 'Resumo' },
  { path: '/config', label: 'Config' },
] as const;

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
autenticada('/resumo', renderResumo);
autenticada('/config', renderConfiguracao);

const appRoot = document.querySelector<HTMLDivElement>('#app')!;
startRouter(appRoot);

supabase.auth.onAuthStateChange((_event, session) => {
  if (!session && window.location.hash !== '#/login') {
    navigate('/login');
  }
});
