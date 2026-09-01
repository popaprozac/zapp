import { defineConfig } from "vite";
import path from "node:path";
import { zapp } from "../vite/src/index.ts";

export default defineConfig({
  plugins: [zapp()],
  resolve: {
    alias: {
      "@zappdev/runtime/worker-globals": path.resolve(import.meta.dirname, "../runtime/worker-globals.ts"),
      "@zappdev/runtime": path.resolve(import.meta.dirname, "../runtime"),
    },
  },
});
