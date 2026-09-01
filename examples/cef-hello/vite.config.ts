import { defineConfig } from "vite";
import path from "node:path";
import { zapp } from "../../vite/src/index.ts";

export default defineConfig({
  // The Zapp CLI resolves zapp.config.ts before starting Vite; the plugin
  // reads that normalized snapshot to discover the headless ticker.
  plugins: [zapp()],
  resolve: {
    alias: {
      "@zappdev/runtime/worker-globals": path.resolve(import.meta.dirname, "../../runtime/worker-globals.ts"),
      "@zappdev/runtime": path.resolve(import.meta.dirname, "../../runtime"),
    },
  },
});
