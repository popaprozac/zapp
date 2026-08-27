import { defineConfig } from "vite";
import path from "node:path";
import { zappWorkers } from "../../../vite/src/index.ts";

export default defineConfig({
  // The CLI snapshot carries the benchmark's headless worker declarations.
  plugins: [zappWorkers()],
  resolve: {
    alias: {
      "@zappdev/runtime/worker-globals": path.resolve(import.meta.dirname, "../../../runtime/worker-globals.ts"),
      "@zappdev/runtime": path.resolve(import.meta.dirname, "../../../runtime"),
    },
  },
});
