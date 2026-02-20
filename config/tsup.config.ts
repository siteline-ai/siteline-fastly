import { defineConfig } from 'tsup';

export default defineConfig({
  entry: {
    index: 'src/handlers/s3-log-processor.ts'
  },
  format: ['cjs'],
  platform: 'node',
  target: 'node18',
  bundle: true,
  sourcemap: true,
  minify: false,
  clean: true,
  outDir: 'dist',
  dts: false,
  noExternal: [/@siteline\/core/, /dotenv/]
});
