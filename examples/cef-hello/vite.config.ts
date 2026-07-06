import { defineConfig } from "vite";
import path from "node:path";
import { zappWorkers } from "../../vite/src/index";
import zappConfig from "./zapp.config";

export default defineConfig({
  // Pass the app's `headless` config to the worker plugin so the `ticker`
  // worker (src/ticker.ts) is bundled to dist/_workers/_headless_ticker.mjs —
  // without this the CLI registers the worker but Vite never emits its script,
  // and the runtime reports "script not found" (mirrors kitchen-sink).
  plugins: [zappWorkers({ headless: zappConfig.headless })],
  resolve: {
    alias: {
      "@zappdev/runtime/worker-globals": path.resolve(__dirname, "../../runtime/worker-globals.ts"),
      "@zappdev/runtime": path.resolve(__dirname, "../../runtime"),
      "@zappdev/cli/config": path.resolve(__dirname, "../../cli/src/config.ts"),
    },
  },
});
