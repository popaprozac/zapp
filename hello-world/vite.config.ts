import { defineConfig } from "vite";
import path from "node:path";
import { zappWorkers } from "../vite/src/index";

export default defineConfig({
  plugins: [zappWorkers()],
  resolve: {
    alias: {
      "@zappdev/runtime/worker-globals": path.resolve(__dirname, "../runtime/worker-globals.ts"),
      "@zappdev/runtime": path.resolve(__dirname, "../runtime"),
    },
  },
});
