import { fileURLToPath } from "node:url";
import { zapp } from "../../vite/src/index.ts";
import { svelte } from "@sveltejs/vite-plugin-svelte";

// The in-repository application uses Vite pinned at the workspace root.
// An ordinary generated application declares Vite in its own package.json.
export default {
  root: "frontend",
  // Ordinary Svelte CSS extraction for the owner. The inspector's stylesheet
  // is explicitly owned by its related document (see related-inspectors.ts).
  plugins: [svelte(), zapp()],
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
      "@zappdev/runtime/shell": fileURLToPath(
        new URL("../../runtime/shell-public.ts", import.meta.url),
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
