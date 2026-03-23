import { defineConfig } from "@zapp/cli/config";

export default defineConfig({
  name: "Zapp Playground",
  identifier: "com.zapp.playground",
  version: "0.0.1",
  icon: "./assets/icon.png",
  description: "Zapp framework playground and testing app",
  author: "Zapp",
  macos: {
    minimumSystemVersion: "13.0",
    category: "public.app-category.developer-tools",
  },
});
