import { fileURLToPath, URL } from 'node:url'
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// The API's origin. In dev we proxy so the browser sees one origin and we
// never have to think about CORS or cookie-less cross-site quirks.
const API_TARGET = process.env.ENKA_API_URL ?? 'http://localhost:8010'

export default defineConfig({
  plugins: [vue()],
  resolve: {
    alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) },
  },
  server: {
    port: 5273,
    proxy: {
      '/api': { target: API_TARGET, changeOrigin: true },
      '/health': { target: API_TARGET, changeOrigin: true },
    },
  },
})
