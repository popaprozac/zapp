import { defineConfig } from "vite";
import path from "node:path";
import { zappWorkers } from "../../vite/src/index";

export default defineConfig({
  // No headless workers in this fixture (dead-minimal: one window, one
  // service, one button) — zappWorkers() with no options still wires up
  // the auto-discovered-worker + asset plumbing every Zapp app needs.
  plugins: [zappWorkers()],
  resolve: {
    alias: {
      "@zappdev/runtime/worker-globals": path.resolve(__dirname, "../../runtime/worker-globals.ts"),
      "@zappdev/runtime": path.resolve(__dirname, "../../runtime"),
      "@zappdev/cli/config": path.resolve(__dirname, "../../cli/src/config.ts"),
    },
  },
});
