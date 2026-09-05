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
      "@zappdev/runtime/application": fileURLToPath(
        new URL("../../runtime/application-api.ts", import.meta.url),
      ),
      "@zappdev/runtime/clipboard": fileURLToPath(
        new URL("../../runtime/clipboard-public.ts", import.meta.url),
      ),
      "@zappdev/runtime/notifications": fileURLToPath(
        new URL("../../runtime/notifications-public.ts", import.meta.url),
      ),
      "@zappdev/runtime/menu": fileURLToPath(
        new URL("../../runtime/menu-public.ts", import.meta.url),
      ),
      "@zappdev/runtime/window": fileURLToPath(
        new URL("../../runtime/window-api.ts", import.meta.url),
      ),
    },
  },
  build: {
    outDir: "../dist",
    emptyOutDir: true,
  },
};
