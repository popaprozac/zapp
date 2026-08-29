import { defineConfig } from "vite";
import wails from "@wailsio/runtime/plugins/vite";

export default defineConfig({
  build: {
    target: "es2022",
  },
  plugins: [wails("./bindings")],
});
