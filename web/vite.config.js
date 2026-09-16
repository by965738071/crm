import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// base=/static/：构建产物内所有资源引用走 /static/*，由后端 StaticFileServer 托管；
// index.html 本身放 web/dist 根，由后端 "/" 路由 + SPA 回退提供。
export default defineConfig({
  base: '/',
  plugins: [vue()],
  server: {
    port: 5173,
    proxy: {
      // 开发期把 /api 代理到本地 crm 服务（cookie 同源直传）
      '/api': 'http://127.0.0.1:8080',
    },
  },
  build: {
    outDir: 'dist',
    chunkSizeWarningLimit: 1200,
  },
})
