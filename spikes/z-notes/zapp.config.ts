import { defineConfig } from "../../cli/src/config";

export default defineConfig({
  application: {
    name: "Z Notes",
    identifier: "com.zapp.z-notes",
    version: "0.1.0",
  },
  frontend: {
    assets: "./dist",
  },
  webview: {
    inject: {
      base: {
        styles: ["./frontend/injected/base.css"],
        documentStart: ["./frontend/injected/preload.ts"],
        documentEnd: ["./frontend/injected/ready.ts"],
      },
    },
  },
});
