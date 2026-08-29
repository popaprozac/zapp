import type { ElectrobunConfig } from "electrobun";

export default {
  app: {
    name: "z-notes-benchmark-electrobun",
    identifier: "com.zapp.benchmark.z-notes-electrobun",
    version: "0.1.0",
  },
  build: {
    mainProcess: "cottontail",
    cottontail: {
      entrypoint: "src/main/index.ts",
    },
    views: {
      mainview: {
        entrypoint: "src/mainview/index.ts",
      },
    },
    copy: {
      "src/mainview/index.html": "views/mainview/index.html",
    },
    mac: {
      bundleCEF: false,
      icons: "../../../../assets/zapp.icon",
    },
    linux: {
      bundleCEF: false,
    },
    win: {
      bundleCEF: false,
    },
  },
} satisfies ElectrobunConfig;
