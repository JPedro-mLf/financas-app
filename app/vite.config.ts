import { defineConfig } from 'vite';
import { VitePWA } from 'vite-plugin-pwa';

// GitHub Pages serve o projeto num subcaminho (https://<usuario>.github.io/financas-app/),
// entao o build precisa desse base -- mas o dev server local continua na raiz.
export default defineConfig(({ command }) => ({
  base: command === 'build' ? '/financas-app/' : '/',
  plugins: [
    VitePWA({
      registerType: 'autoUpdate',
      manifest: {
        name: 'Financas',
        short_name: 'Financas',
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
