// Zapp config loader — reads zapp.config.ts

import path from "node:path";

export interface SecurityConfig {
  /** URL patterns allowed to navigate to. Supports glob (trailing *). */
  allowNavigation?: string[];
}

export interface MacOSConfig {
  /** Accept first mouse click on unfocused window. Default: true */
  acceptFirstMouse?: boolean;
  /** Path to .icns icon file. */
  icon?: string;
  /** App Store category (e.g. "public.app-category.developer-tools"). */
  category?: string;
  /** Minimum macOS version. Default: "12.0" */
  minimumSystemVersion?: string;
  /** Code signing identity. Omit for ad-hoc. */
  signingIdentity?: string;
}

export interface ZappConfig {
  name: string;
  identifier?: string;
  version?: string;
  assetDir?: string;  // Default: "./dist" (Vite), configurable for static sites
  devPort?: number;   // Default: 5173
  /**
   * Headless workers to start at app boot, keyed by ID.
   * Example: `{ db: "src/workers/db.ts", sync: "src/workers/sync.ts" }`
   * IDs are used for termination via `Workers.terminate(id)`.
   */
  headless?: Record<string, string>;
  deepLinkSchemes?: string[];  // e.g. ["myapp"] → registers myapp:// URL scheme
  macos?: MacOSConfig;
  security?: SecurityConfig;
}

export interface ResolvedConfig extends ZappConfig {
  assetDir: string;
}

export function defineConfig(config: ZappConfig): ZappConfig {
  return config;
}

export async function loadConfig(root: string): Promise<ResolvedConfig> {
  const configPath = path.join(root, "zapp.config.ts");
  try {
    const mod = await import(configPath);
    // Support both `export default defineConfig({...})` and `export default {...}`
    const config = (typeof mod.default === "function" ? mod.default() : mod.default) as ZappConfig;
    return {
      ...config,
      assetDir: config.assetDir ?? "./dist",
    };
  } catch {
    return {
      name: path.basename(root),
      assetDir: "./dist",
    };
  }
}
