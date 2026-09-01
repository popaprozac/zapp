import { fileURLToPath } from "node:url";
import { zapp } from "../../vite/src/index.ts";

// Keep the in-repository application self-contained. `zapp dev` supplies Vite
// through the CLI, while an ordinary generated application declares Vite in
// its own package.json and may use `defineConfig` for richer typing.
export default {
  root: "frontend",
  plugins: [zapp()],
  resolve: {
    alias: {
      "@zappdev/runtime/window": fileURLToPath(
        new URL("../../runtime/window.ts", import.meta.url),
      ),
    },
  },
  build: {
    outDir: "../dist",
    emptyOutDir: true,
  },
};
