import tailwindcss from '@tailwindcss/vite';
import react from '@vitejs/plugin-react';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vite';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export default defineConfig(({ mode }) => {
  if (mode === 'preload') {
    return {
      build: {
        emptyOutDir: false,
        lib: {
          entry: path.resolve(__dirname, 'src/preload.ts'),
          fileName: () => 'preload.js',
          formats: ['cjs']
        },
        outDir: 'dist-main',
        rolldownOptions: {
          external: ['electron']
        }
      }
    };
  }

  return {
    base: './',
    plugins: [react(), tailwindcss()],
    root: '.',
    resolve: {
      // shadcn/ui 惯例别名:组件源码里的 `@/lib/utils`、`@/components/ui/*`。
      alias: { '@': path.resolve(__dirname, 'src/renderer') }
    },
    build: {
      outDir: 'dist-renderer'
    }
  };
});
