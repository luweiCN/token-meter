import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  resolve: {
    // 与 vite.config.ts 同步:shadcn 组件源码里的 `@/lib/utils` 等别名。
    alias: { '@': path.resolve(__dirname, 'src/renderer') }
  },
  test: {
    environment: 'node',
    globals: true,
    restoreMocks: true,
    setupFiles: ['./src/test/setupRenderer.ts']
  }
});
