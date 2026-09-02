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
  security: {
    permissions: ["window:create"],
    capabilities: {
      default: {
        permissions: ["window:create"],
        services: ["notes", "health"],
        workers: ["lifecycle"],
      },
      diagnostics: {
        services: ["notes.count", "notes.isEmpty", "notes.list", "health.status"],
      },
    },
  },
  webview: {
    inject: {
      base: {
        styles: ["./frontend/injected/base.css"],
        documentStart: ["./frontend/injected/preload.ts"],
        documentEnd: ["./frontend/injected/ready.ts"],
      },
      diagnostics: {
        documentStart: ["./frontend/injected/diagnostics.ts"],
      },
    },
  },
  workers: {
    application: {
      lifecycle: {
        script: "./frontend/worker-lifecycle.ts",
        engine: "zjs",
        capabilities: ["diagnostics"],
      },
      ...(process.env.ZAPP_APPLICATION_WORKER_RESTART_SMOKE === "1" ? {
        restartProbe: {
          script: "./frontend/worker-restart.ts",
          engine: "zjs",
          restart: { maxRetries: 2, withinMs: 60_000 },
        },
      } : {}),
    },
  },
});
