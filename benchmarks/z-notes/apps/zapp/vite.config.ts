import { fileURLToPath } from "node:url";
import { zapp } from "../../../../vite/src/index.ts";

export default {
  root: "frontend",
  plugins: [zapp()],
  resolve: {
    alias: {
      "@zappdev/runtime": fileURLToPath(
        new URL("../../../../runtime/index.ts", import.meta.url),
      ),
    },
  },
  build: {
    outDir: "../dist",
    emptyOutDir: true,
  },
};
