import { defineConfig } from "vite";
import path from "node:path";
import { zappWorkers } from "../../../vite/src/index.ts";
import zappConfig from "./zapp.config.ts";

export default defineConfig({
  // Pass headless workers so the Vite plugin bundles them under
  // /_workers/_headless_<key>.mjs alongside instance workers. Without
  // this, the bench-* headless entries declared in zapp.config.ts
  // never get bundled and the native loader can't find them.
  plugins: [zappWorkers({ headless: zappConfig.headless })],
  resolve: {
    alias: {
      "@zappdev/runtime/worker-globals": path.resolve(import.meta.dirname, "../../../runtime/worker-globals.ts"),
      "@zappdev/runtime": path.resolve(import.meta.dirname, "../../../runtime"),
    },
  },
});
