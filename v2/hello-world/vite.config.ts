import { defineConfig } from "vite";
import path from "node:path";

export default defineConfig({
  resolve: {
    alias: {
      "@zappdev/runtime": path.resolve(__dirname, "../runtime"),
    },
  },
});
