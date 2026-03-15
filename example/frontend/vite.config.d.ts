declare module "../../packages/vite-plugin-zapp-workers/index.mjs" {
  export function zappWorkers(options?: {
    outDir?: string;
    sourceRoot?: string;
    minify?: boolean;
  }): import("vite").Plugin;
}
