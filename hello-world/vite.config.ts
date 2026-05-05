import { defineConfig } from "vite";
import path from "node:path";
import { zappWorkers } from "../vite/src/index";
import zappConfig from "./zapp.config";

export default defineConfig({
  // Pull headless workers from zapp.config.ts so a single declaration
  // drives both the native build (via the CLI) and the Vite bundle.
  plugins: [zappWorkers({ headless: zappConfig.headless })],
  resolve: {
    alias: {
      "@zappdev/runtime/worker-globals": path.resolve(__dirname, "../runtime/worker-globals.ts"),
      "@zappdev/runtime": path.resolve(__dirname, "../runtime"),
    },
  },
});
