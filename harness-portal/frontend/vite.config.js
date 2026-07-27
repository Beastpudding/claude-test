import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// The portal is served behind JupyterHub at /services/harness-portal/.
// `base` makes built asset URLs + import.meta.env.BASE_URL resolve under that
// prefix. Overridable at build time via VITE_BASE (e.g. "/" for local dev).
// https://vitejs.dev/config/
export default defineConfig({
  base: process.env.VITE_BASE || '/services/harness-portal/',
  plugins: [react()],
  server: {
    host: '0.0.0.0',
    port: 3000,
    proxy: {
      '/api': {
        target: 'http://localhost:8000',
        changeOrigin: true,
        ws: true
      }
    }
  }
})
