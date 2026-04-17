// Zapp config loader — reads zapp.config.ts

import path from "node:path";

export interface MacOSConfig {
  /**
   * Path to an icon. Supported formats: `.icon` (Icon Composer, best for
   * macOS 26+), `.icns`, `.iconset`, `.png` (1024×1024). Path is relative
   * to the project root or absolute.
   *
   * If omitted, the CLI looks for `build/macos/icon.{icon,icns,iconset,png}`
   * in the project, then falls back to the framework default.
   */
  icon?: string;
  /** App Store category (e.g. "public.app-category.developer-tools"). */
  category?: string;
  /** Minimum macOS version. Default: "12.0" */
  minimumSystemVersion?: string;
  /** Code signing identity. Omit for ad-hoc. */
  signingIdentity?: string;

  /** Copyright string → `NSHumanReadableCopyright` in Info.plist. */
  copyright?: string;

  /**
   * Privacy usage descriptions shown in macOS permission prompts. Each
   * string explains why the app needs access. Required by macOS for
   * any of these capabilities — apps requesting them without a usage
   * description will crash.
   */
  usageDescriptions?: {
    camera?: string;       // → NSCameraUsageDescription
    microphone?: string;   // → NSMicrophoneUsageDescription
    location?: string;     // → NSLocationUsageDescription
    photos?: string;       // → NSPhotoLibraryUsageDescription
    documents?: string;    // → NSDocumentsFolderUsageDescription
    downloads?: string;    // → NSDownloadsFolderUsageDescription
    desktop?: string;      // → NSDesktopFolderUsageDescription
    network?: string;      // → NSLocalNetworkUsageDescription
    bluetooth?: string;    // → NSBluetoothAlwaysUsageDescription
    appleEvents?: string;  // → NSAppleEventsUsageDescription
  };

  /**
   * Arbitrary additional Info.plist keys. Each key/value pair is merged
   * into the generated plist's top-level `<dict>`. Use this for anything
   * not covered by typed fields. Values are converted by type:
   *  - `string` → `<string>...</string>`
   *  - `number` → `<integer>...</integer>` (or `<real>` if fractional)
   *  - `boolean` → `<true/>` / `<false/>`
   *  - `string[]` → `<array><string>...</string></array>`
   *
   * For nested dicts/arrays of mixed types, use `plistFile` instead.
   */
  plistExtras?: Record<string, string | number | boolean | string[]>;

  /**
   * Path to a partial Info.plist file whose contents are merged into the
   * generated plist. Should contain ONLY `<key>...</key><value/>` pairs
   * — no `<plist>` or `<dict>` wrappers. Default: `build/macos/Info.plist.extra`
   * if present.
   *
   * Keys here override CLI-derived defaults; the CLI logs a warning
   * when this happens.
   */
  plistFile?: string;

  /**
   * Code-signing entitlements as key/value pairs. Emitted as a standalone
   * `Entitlements.plist` at build time and passed to `codesign --entitlements`
   * during both `zapp dev` and `zapp package`. Use for things like
   * `com.apple.security.app-sandbox`, `com.apple.security.network.client`,
   * or `com.apple.developer.default-data-protection` — see Apple's
   * "Entitlements" reference for the full list.
   *
   * Values follow the same type rules as `plistExtras`:
   *  - `string` → `<string>...</string>`
   *  - `number` → `<integer>...</integer>` (or `<real>` if fractional)
   *  - `boolean` → `<true/>` / `<false/>`
   *  - `string[]` → `<array><string>...</string></array>`
   *
   * Note: entitlements that require a provisioning profile (e.g. data
   * protection, iCloud, App Groups) only take effect when the binary is
   * signed with a real `signingIdentity` — ad-hoc signing silently
   * ignores them. The CLI warns when this mismatch is detected.
   */
  entitlements?: Record<string, string | number | boolean | string[]>;

  /**
   * Path to a `.entitlements` file. Its top-level `<dict>` contents are
   * merged into the generated `Entitlements.plist`; keys from
   * `entitlements` win on conflict (CLI warns). Default:
   * `build/macos/app.entitlements` if present.
   *
   * Use this for entitlements too complex for the typed map (nested dicts,
   * mixed arrays), or to share a canonical file across multiple projects.
   */
  entitlementsFile?: string;
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
