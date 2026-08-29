import { defineConfig } from "../../../../cli/src/config";

export default defineConfig({
  application: {
    name: "Z Notes Benchmark",
    identifier: "com.zapp.benchmark.z-notes",
    version: "0.1.0",
  },
  frontend: {
    assets: "./dist",
  },
  security: {
    capabilities: {
      default: {
        services: ["notes"],
      },
    },
  },
});
