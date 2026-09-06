import { defineConfig } from "../../cli/src/config";

export default defineConfig({
  application: {
    name: "Z Notes",
    identifier: process.env.ZAPP_Z_NOTES_IDENTIFIER ?? "com.zapp.z-notes",
    version: "0.1.0",
  },
  frontend: {
    assets: "./dist",
  },
  security: {
    permissions: [
      "window:create",
      "menu",
      "fs:read",
      "fs:write",
      "clipboard:read",
      "clipboard:write",
      "notifications",
      "shell:open",
      "shell:reveal",
    ],
    capabilities: {
      default: {
        permissions: [
          "window:create",
          "menu",
          "fs:read",
          "fs:write",
          "clipboard:read",
          "clipboard:write",
          "notifications",
          "shell:open",
          "shell:reveal",
        ],
        services: ["notes", "health"],
        workers: ["noteIndexer"],
      },
      diagnostics: {
        services: ["notes.count", "notes.isEmpty", "notes.list", "health.status"],
      },
    },
    navigation: {
      default: {
        navigate: ["self", "https://docs.z-language.com"],
        openExternal: ["https:", "mailto:"],
      },
    },
    filesystem: {
      allow: ["$resources"],
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
      noteIndexer: {
        script: "./frontend/note-indexer.ts",
        engine: "zjs",
        capabilities: ["diagnostics"],
        protocol: {
          module: "./zapp/note-indexer-protocol.zs",
          type: "NoteIndexerProtocol",
        },
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
  targets: {
    macOS: {
      minimumSystemVersion: "14.0",
    },
  },
});
