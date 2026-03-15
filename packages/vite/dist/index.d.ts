import type { Plugin } from "vite";
export interface ZappOptions {
    outDir?: string;
    sourceRoot?: string;
    minify?: boolean;
}
export declare const zapp: (options?: ZappOptions) => Plugin;
export default zapp;
