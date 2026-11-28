import { defineConfig } from 'vite';
import { VitePWA } from 'vite-plugin-pwa';

// GitHub Pages serve o projeto num subcaminho (https://<usuario>.github.io/financas-app/),
// entao o build precisa desse base -- mas o dev server local continua na raiz.
//
// O mesmo codigo tambem e publicado em /financas-app/v2/, apontando para o
// projeto Supabase da integracao Open Finance (ESPECIFICACAO.md 14.18): o
// workflow de deploy builda de novo com VITE_AMBIENTE=v2 e BASE_PATH proprio.
const ehV2 = process.env.VITE_AMBIENTE === 'v2';
const basePublicado = process.env.BASE_PATH ?? '/financas-app/';

export default defineConfig(({ command }) => ({
  base: command === 'build' ? basePublicado : '/',
  plugins: [
    VitePWA({
      registerType: 'autoUpdate',
      workbox: {
        // O service worker de producao (escopo /financas-app/) cobre tambem
        // /financas-app/v2/; sem isto ele responderia as navegacoes do v2 com
        // o index.html de producao.
        navigateFallbackDenylist: ehV2 ? [] : [/\/v2\//],
      },
      manifest: {
        name: ehV2 ? 'Financas v2 (teste)' : 'Financas',
        short_name: ehV2 ? 'Financas v2' : 'Financas',
        description: 'Controle financeiro pessoal',
        start_url: '.',
        display: 'standalone',
        background_color: '#0f1115',
        theme_color: '#0f1115',
        icons: [
          { src: 'favicon.svg', sizes: 'any', type: 'image/svg+xml', purpose: 'any' },
        ],
      },
    }),
  ],
}));
