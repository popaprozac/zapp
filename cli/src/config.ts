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

  /**
   * Apple notarization credentials. When set (and `signingIdentity`
   * is a real Developer ID, not ad-hoc), `zapp package --notarize`
   * submits the signed `.app` to Apple, waits for approval, and
   * staples the ticket so it opens cleanly on other Macs without a
   * "downloaded from internet" warning.
   *
   * **Three auth paths**, in order of preference:
   *
   *   1. **Keychain profile** — fastest local setup. Run once:
   *      `xcrun notarytool store-credentials zapp-notarize`.
   *      Then set `keychainProfile: "zapp-notarize"`.
   *
   *   2. **API key** — recommended for CI. Generates a `.p8` from
   *      App Store Connect. Set `apiKeyPath` / `apiKeyId` /
   *      `apiIssuerId`. The .p8 stays on disk; no password in
   *      env or config.
   *
   *   3. **Apple ID + app-specific password** — legacy but works.
   *      Password should NOT live in config; set
   *      `ZAPP_NOTARIZE_APPLE_PASSWORD` env var instead.
   *
   * Every field can be overridden by an env var
   * (`ZAPP_NOTARIZE_<UPPERCASE_FIELD>`) so secrets stay out of
   * `zapp.config.ts`.
   */
  notarize?: {
    /** Keychain profile name (created via `xcrun notarytool store-credentials`). */
    keychainProfile?: string;
    /** Path to App Store Connect API key (.p8 file). Pair with apiKeyId + apiIssuerId. */
    apiKeyPath?: string;
    apiKeyId?: string;
    apiIssuerId?: string;
    /** Apple ID email. Pair with teamId; password from env var. */
    appleId?: string;
    teamId?: string;
  };

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

/**
 * Filesystem allowlist. Every path Zapp's FS APIs touch must be under one
 * of the patterns declared here. Path variables ($userData, $temp, etc.)
 * are expanded at runtime.
 *
 * Granted paths from `Dialog.openFile` / `Dialog.openDirectory` also
 * extend the allowlist for the session (and persist across launches if
 * `persistDialogGrants` is true).
 *
 * @example
 * ```ts
 * fs: {
 *   allow: ["$userData", "$temp", "~/Documents/MyApp"],
 *   persistDialogGrants: true,
 * }
 * ```
 */
export interface FsConfig {
  /** Path patterns the app may read/write. Paths may use `$var` or `~/…` prefixes. */
  allow?: string[];
  /** Persist `Dialog.openFile`-granted paths across app launches. Default: `false`. */
  persistDialogGrants?: boolean;
}

/**
 * iOS-specific configuration. Parallel to `MacOSConfig` but with
 * iOS-specific keys (UIDeviceFamily, UIBackgroundModes, etc.) and a
 * typed `capabilities` map for the most common entitlements. iPad and
 * iPhone share this config; treat iPad as iPhone in Phase 1-3 unless
 * `deviceFamily: "ipad"` is set.
 *
 * Phase 1 surface — Simulator only, no signing required. Production
 * fields (provisioningProfile, signingTeamId) are honored when
 * present but not required for `zapp build --platform ios`.
 *
 * See `/Users/zach/.claude/plans/ios-strategic-scoping.md` for the
 * full iOS roadmap including phases 2-4 (API parity, App Store
 * distribution, mobile-specific features).
 */
export interface IOSConfig {
  /**
   * Path to a 1024×1024 PNG icon source. The CLI generates the iOS
   * Assets.xcassets/AppIcon.appiconset/ scales from this. If omitted,
   * looks for `build/ios/icon.png`, then `build/icon.png`.
   */
  icon?: string;

  /** Minimum iOS deployment target. Default: `"15.0"`. */
  minimumSystemVersion?: string;

  /**
   * Which device families the app targets:
   * - `"iphone"` — UIDeviceFamily = [1]
   * - `"ipad"` — UIDeviceFamily = [2]
   * - `"universal"` — UIDeviceFamily = [1, 2] (default)
   */
  deviceFamily?: "iphone" | "ipad" | "universal";

  /**
   * Apple Developer Team ID for code-signing. Required for device
   * builds and TestFlight upload; not required for Simulator.
   */
  signingTeamId?: string;

  /**
   * Path to the .mobileprovision file. Required for device / App
   * Store builds; not required for Simulator. Per-developer; should
   * be gitignored.
   */
  provisioningProfile?: string;

  /**
   * Typed shortcuts for common iOS entitlements. The CLI translates
   * each enabled capability into the corresponding plist + entitlement
   * keys. For things not covered here, use `entitlements` below.
   */
  capabilities?: {
    /** Adds `aps-environment` entitlement. Required for APNs. */
    pushNotifications?: boolean;
    /** Adds `fetch` to UIBackgroundModes. */
    backgroundFetch?: boolean;
    /** Adds `processing` to UIBackgroundModes (BGTaskScheduler). */
    backgroundProcessing?: boolean;
    /** Adds `com.apple.developer.icloud-services` entitlement. */
    iCloud?: boolean;
    /** Enables keychain access groups. */
    keychainSharing?: boolean;
  };

  /**
   * UIBackgroundModes plist key. Each string is one mode:
   * "audio", "location", "voip", "fetch", "processing", "remote-notification",
   * "external-accessory", "bluetooth-central", "bluetooth-peripheral".
   * Most apps don't need this; use `capabilities.backgroundFetch`
   * for the common case.
   */
  backgroundModes?: string[];

  /**
   * Privacy usage descriptions. Same shape as `MacOSConfig` minus
   * macOS-only keys (documents/downloads/desktop/appleEvents).
   */
  usageDescriptions?: {
    camera?: string;
    microphone?: string;
    location?: string;
    photos?: string;
    bluetooth?: string;
    network?: string;     // → NSLocalNetworkUsageDescription (iOS 14+)
  };

  /** iOS-specific Info.plist extras (e.g. UISupportedInterfaceOrientations). */
  plistExtras?: Record<string, string | number | boolean | string[]>;

  /**
   * Partial Info.plist file (key/value pairs only — no plist/dict
   * wrappers). Default: `build/ios/Info.plist.extra` if present.
   */
  plistFile?: string;

  /**
   * Free-form iOS entitlements. Use for things `capabilities` doesn't
   * cover (e.g. App Groups, HealthKit, etc.).
   */
  entitlements?: Record<string, string | number | boolean | string[]>;

  /**
   * Path to a .entitlements XML file. Default: `build/ios/app.entitlements`
   * if present. Merges with the typed `entitlements` map; the typed
   * map wins on conflict.
   */
  entitlementsFile?: string;
}

/**
 * Restart policy applied to a supervised headless worker. The
 * supervisor counts uncaught failures within a sliding `withinMs`
 * window; once `maxRetries` is exceeded, the worker is given up on
 * and `worker:gave-up` fires (instead of `worker:restarted`).
 *
 * Defaults when `restart: {}` is set without explicit fields:
 *   `maxRetries: 3`, `withinMs: 60_000`.
 */
export interface RestartPolicy {
  /** Max consecutive failures inside `withinMs` before giving up. Default 3. */
  maxRetries?: number;
  /** Sliding-window length in milliseconds. Default 60_000 (1 min). */
  withinMs?: number;
}

export interface HeadlessWorkerConfig {
  /** Script path (same as the bare-string form). */
  script: string;
  /** Optional restart policy. Omit / `false` to disable auto-restart. */
  restart?: RestartPolicy | false;
  /**
   * Per-worker engine selection (G8). `"jsc"` is the default — zero
   * binary cost on Apple, JIT for hot JS loops, no fetch / WebSocket /
   * Streams. `"txiki"` opts this specific worker into the txiki.js
   * runtime — full web APIs (fetch, WebSocket, Streams, SQLite via
   * FFI) and a faster worker→native call rate, at the cost of pulling
   * in the txiki engine (~6 MB if not already linked).
   *
   * Both engines must be enabled at build time (`ZAPP_WORKER_ENGINE_JSC`
   * + `ZAPP_WORKER_ENGINE_TXIKI`) for true mixing. When only one is
   * compiled, requests for the other are downgraded with a warning so
   * the surprise is visible during dev.
   */
  engine?: "jsc" | "txiki";
}

export interface ZappConfig {
  name: string;
  identifier?: string;
  version?: string;
  assetDir?: string;  // Default: "./dist" (Vite), configurable for static sites
  devPort?: number;   // Default: 5173
  /**
   * Headless workers to start at app boot, keyed by ID.
   *
   * Two shapes per entry:
   *
   *   - `string` — script path. Worker starts at boot, no auto-restart.
   *   - `{ script, restart? }` — same plus an optional restart policy.
   *
   * IDs are used for termination via `Workers.terminate(id)` and for
   * the supervisor's `worker:crashed` / `worker:restarted` /
   * `worker:gave-up` events.
   *
   * @example
   * ```ts
   * headless: {
   *   db: "src/workers/db.ts",                     // simple
   *   sync: {
   *     script: "src/workers/sync.ts",
   *     restart: { maxRetries: 3, withinMs: 60_000 }, // supervised
   *   },
   * }
   * ```
   */
  headless?: Record<string, string | HeadlessWorkerConfig>;
  deepLinkSchemes?: string[];  // e.g. ["myapp"] → registers myapp:// URL scheme
  /**
   * Custom in-webview URL protocols (G19). Each scheme listed here
   * is registered on every WKWebView's configuration so navigation
   * / fetch requests with that scheme route to a JS handler registered
   * via `Protocols.register("scheme", handler)` in the runtime.
   *
   * Use cases:
   *  - `"asset"` for app-managed user uploads served from a DB or
   *    encrypted store
   *  - `"media"` for on-the-fly resized / transcoded images
   *  - `"vault"` for content that must be decrypted before reaching
   *    the webview
   *
   * **Different from `deepLinkSchemes`** — those are system-wide URL
   * schemes registered with macOS so `myapp://open/...` from another
   * app fires `App.on(AppEvent.OPEN_URL, ...)`. `protocols` are
   * webview-internal: they only intercept requests inside Zapp's
   * own WebViews.
   *
   * Schemes must be declared at build time (WKWebView's scheme
   * registration is config-time only — can't be added after a
   * webview is created).
   *
   * @example
   * ```ts
   * protocols: ["asset", "media"]
   * ```
   */
  protocols?: string[];
  /**
   * Single-instance enforcement. When `true`, only one copy of the app
   * can run at a time — Launch Services refuses second-launch attempts
   * (`open -n` / duplicated bundles). On macOS this maps to
   * `LSMultipleInstancesProhibited` in Info.plist.
   *
   * Deep-link clicks (`myapp://...`) and dock-icon reopens already
   * route to the running instance via `App.on(AppEvent.OPEN_URL)` /
   * `AppEvent.REOPEN`; `singleInstance: true` prevents the duplicate
   * instances that would otherwise be spawned by `open -n`.
   *
   * Default: `false` (matches macOS-native behavior). Most desktop apps
   * want `true`; menu-bar / sync-engine apps almost always want `true`
   * to keep local state coherent.
   *
   * No-op on iOS (apps are always single-instance there by platform
   * contract). Windows handling lands later.
   */
  singleInstance?: boolean;
  /** Filesystem allowlist. See {@link FsConfig}. */
  fs?: FsConfig;
  macos?: MacOSConfig;
  /** iOS-specific configuration. See {@link IOSConfig}. */
  ios?: IOSConfig;
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
