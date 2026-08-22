import { defineConfig } from "vite";
import path from "node:path";
import { zappWorkers } from "../vite/src/index.ts";
import zappConfig from "./zapp.config.ts";

export default defineConfig({
  plugins: [zappWorkers({ headless: zappConfig.headless })],
  resolve: {
    alias: {
      "@zappdev/runtime/worker-globals": path.resolve(import.meta.dirname, "../runtime/worker-globals.ts"),
      "@zappdev/runtime": path.resolve(import.meta.dirname, "../runtime"),
      "@zappdev/cli/config": path.resolve(import.meta.dirname, "../cli/src/config.ts"),
    },
  },
});
