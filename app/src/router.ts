type RenderFn = (root: HTMLElement) => void | Promise<void>;

const routes = new Map<string, RenderFn>();
let rootEl: HTMLElement | null = null;

export function registerRoute(path: string, render: RenderFn): void {
  routes.set(path, render);
}

export function navigate(path: string): void {
  if (currentPath() === path) {
    void renderCurrent();
    return;
  }
  window.location.hash = path;
}

export function startRouter(root: HTMLElement): void {
  rootEl = root;
  window.addEventListener('hashchange', () => void renderCurrent());
  void renderCurrent();
}

function currentPath(): string {
  return window.location.hash.replace(/^#/, '') || '/';
}

async function renderCurrent(): Promise<void> {
  if (!rootEl) return;
  const render = routes.get(currentPath()) ?? routes.get('/');
  if (render) await render(rootEl);
}
