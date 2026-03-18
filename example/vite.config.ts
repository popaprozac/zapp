import { defineConfig } from 'vite'
import { svelte } from '@sveltejs/vite-plugin-svelte'
import path from 'node:path'
import { zapp } from '@zapp/vite'

export default defineConfig({
  plugins: [
    svelte(),
    zapp({
      sourceRoot: 'src',
      minify: false,
    }),
  ],
  resolve: {
    alias: {
      '@zapp/runtime': path.resolve(__dirname, '../packages/runtime/index.ts'),
    },
  },
  worker: {
    format: 'es',
  }
})
