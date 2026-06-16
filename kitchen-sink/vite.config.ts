import { defineConfig } from "vite";
import path from "node:path";
import { zappWorkers } from "../vite/src/index";
import zappConfig from "./zapp.config";

export default defineConfig({
  plugins: [zappWorkers({ headless: zappConfig.headless })],
  resolve: {
    alias: {
      "@zappdev/runtime/worker-globals": path.resolve(__dirname, "../runtime/worker-globals.ts"),
      "@zappdev/runtime": path.resolve(__dirname, "../runtime"),
      "@zappdev/cli/config": path.resolve(__dirname, "../cli/src/config.ts"),
    },
  },
});
