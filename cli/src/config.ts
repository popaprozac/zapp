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
   * Per-worker engine selection.
   *
   * - `"jsc"` (legacy default) — native Cocoa JSContext. Zero binary
   *   cost on Apple, JIT for hot JS loops, but no fetch / WebSocket /
   *   Streams in the worker context.
   * - `"txiki"` (legacy) — txiki.js runtime. Full web APIs, no JIT,
   *   ~6 MB binary cost.
   * - `"bare-jsc"` — Bare runtime + JSC engine. JIT on macOS (free
   *   binary cost on Apple via system framework), à la carte web APIs
   *   from `bare-fetch` / `bare-ws` / `bare-crypto` / etc.
   * - `"bare-v8"` — Bare runtime + V8. JIT all platforms; larger
   *   binary, sensible for Windows / Linux where there's no system
   *   JSC.
   * - `"bare-quickjs"` — Bare runtime + QuickJS. No JIT, smallest
   *   cross-platform footprint after JSC.
   * - `"bare-mqjs"` — Bare runtime + micro-QuickJS. Embedded / IoT
   *   profile.
   * - `"bare-hermes"` — Bare runtime + Hermes. AOT bytecode + tier-up
   *   interpreter. iOS-friendly (no JIT entitlement needed).
   * - `"zjs"` — Zapp's first-party engine (popaprozac/zjs). Smallest
   *   binary (1 MB static lib), iOS-friendly (no JIT requirement),
   *   direct value-marshalling host bridge (skips JS-side
   *   `JSON.stringify` on the way into `Services.invokeSync`). No bare
   *   runtime — web APIs (fetch, WebSocket) come from zjs's own
   *   runtime layer as it lands them. Best for headless workers that
   *   don't need bare-* packages.
   *
   * The corresponding `ZAPP_WORKER_ENGINE_*` directive must be in
   * `zapp/build.zc` for the engine to be linked in. When the
   * requested engine isn't compiled, the worker dispatcher logs a
   * downgrade and falls back through priority order
   * (zjs > bare-jsc > bare-v8 > bare-hermes > bare-quickjs > bare-mqjs > txiki > jsc).
   */
  engine?: "jsc" | "txiki" | "bare-jsc" | "bare-v8" | "bare-quickjs" | "bare-mqjs" | "bare-hermes" | "zjs";
  /**
   * Pre-compile the worker bundle to bytecode at build time. Only
   * meaningful for `engine: "zjs"` — other engines silently ignore the
   * flag (or error if you set it explicitly elsewhere).
   *
   * When enabled, the CLI runs `zjs compile` against the Vite-bundled
   * .mjs after the build pipeline, writes the result to a sibling
   * `.zbc` file, and ships that as the worker artifact. The engine
   * detects the `.zbc` extension at script-load time and dispatches
   * via `zjs_eval_bytecode` instead of `zjs_eval` — parse-free worker
   * start, faster cold-start (matters most on iOS where JIT is
   * gated by entitlement), smaller embedded asset.
   *
   * Defaults to `false`. Recommended for any zjs worker that hits a
   * cold path (first invocation after app launch) on every run; the
   * tradeoff is one build-time compile step per worker, in exchange
   * for shaving the parse pass off every worker spawn.
   */
  bytecode?: boolean;
}

/**
 * High-level worker capability identifiers. Each maps (via the
 * `WORKER_MODULE_CAPABILITIES` registry in this file) to the
 * underlying bare-* (or txiki) packages a project must install and the
 * `@zappdev/runtime/worker-globals/<subpath>` shim that exposes the
 * matching globals.
 */
export type WorkerModuleId =
  | "fetch"
  | "websocket"
  | "fs"
  | "streams"
  | "crypto"
  | "url"
  | "encoding";

/**
 * Capability → packages + globals subpath registry. Owned by the CLI
 * so a single source of truth drives:
 *  - install verification (`bun install <packages>` if missing)
 *  - native binding link (the side-cmake overlay picks up each
 *    package's `binding.c` when present)
 *  - auto-import (`@zappdev/runtime/worker-globals/<subpath>` is
 *    prepended to every bundled worker entry)
 *
 * `packages` lists the *direct* npm dep(s) needed; transitive
 * bare-* deps (e.g. bare-fetch → bare-tcp/tls/dns/zlib) get
 * resolved by Vite + the overlay automatically.
 *
 * `globals` is the subpath under `@zappdev/runtime/worker-globals`
 * (so `"/fetch"` → `import "@zappdev/runtime/worker-globals/fetch"`).
 * `null` means no global needs to be installed (the package's API
 * is reached via direct import only).
 */
export interface WorkerModuleSpec {
  packages: readonly string[];
  globals: string | null;
}

export const WORKER_MODULE_CAPABILITIES: Record<WorkerModuleId, WorkerModuleSpec> = {
  fetch:     { packages: ["bare-fetch"],    globals: "/fetch" },
  websocket: { packages: ["bare-ws"],       globals: "/websocket" },
  fs:        { packages: ["bare-fs"],       globals: null },
  streams:   { packages: ["bare-stream"],   globals: "/streams" },
  crypto:    { packages: ["bare-crypto"],   globals: "/crypto" },
  url:       { packages: ["bare-url"],      globals: "/url" },
  encoding:  { packages: ["bare-encoding"], globals: "/encoding" },
};

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
  /**
   * Worker capabilities to enable. Each entry is a high-level
   * capability name (e.g. `"fetch"`, `"websocket"`, `"fs"`) — the
   * CLI maps it to the underlying bare-* / txiki package(s),
   * verifies install, and auto-prepends the matching
   * `@zappdev/runtime/worker-globals/<subpath>` import so the
   * global API (`fetch`, `WebSocket`, etc.) is available in every
   * worker without per-worker boilerplate.
   *
   * On bare engines, the package's native bindings (`binding.c`)
   * are also auto-compiled into `libbare_modules.a` via the
   * side-cmake overlay (see `ensureUserBareModulesCompiled`).
   *
   * Same surface across engines — txiki provides most of these
   * APIs natively, so the runtime shim no-ops there. Legacy JSC
   * has no web APIs; CLI doctor warns when capabilities are
   * requested for an engine that can't provide them.
   *
   * @example
   * ```ts
   * workerModules: ["fetch", "websocket"]
   * ```
   *
   * @example
   * ```ts
   * // src/worker.ts — no per-worker imports needed
   * fetch("https://example.com").then(r => r.text());
   * ```
   */
  workerModules?: WorkerModuleId[];
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
  /**
   * Webview engine for the main window. Determines what renders the
   * UI on macOS / Windows / Linux (iOS is always WKWebView by platform
   * contract).
   *
   *   - **`"system"`** *(default)* — system WebView. WKWebView on
   *     macOS, WebView2 on Windows, WebKitGTK on Linux. Tiny binary
   *     (445 KB on macOS), zero runtime overhead, modern web standards.
   *     The right answer for >99% of apps.
   *
   *   - **`"chromium"`** *(early-access)* — bundled Chromium via CEF.
   *     For apps where the system WebView produces a visible rendering
   *     mismatch with desktop Chrome (rare in practice for modern web
   *     stacks; mostly impacts WebGL extensions and certain Web Animations
   *     edge cases). Adds ~150 MB to the binary, so picks a different
   *     trade-off than Zapp's default pitch.
   *
   *     **Not yet implemented.** Setting this today produces a clear
   *     CLI error pointing at the early-access program. Ship-ready
   *     when a real customer surfaces a reproducible "system WebView
   *     won't render X" requirement.
   *
   * @default "system"
   */
  webEngine?: "system" | "chromium";
}

export interface ResolvedConfig extends ZappConfig {
  assetDir: string;
}

export function defineConfig(config: ZappConfig): ZappConfig {
  return config;
}

// Reject `webEngine: "chromium"` with a clear next-step. The field exists
// in the type (and on the landing page comparison matrix), but bundling
// CEF / Chromium is gated on a real customer surfacing a reproducible
// "system WebView won't render X" requirement — see
// /Users/zach/.claude/plans/polished-mapping-ullman.md.
function validateWebEngine(engine?: ZappConfig["webEngine"]): void {
  if (engine === undefined || engine === "system") return;
  if (engine === "chromium") {
    throw new Error(
      "[zapp] webEngine: \"chromium\" is early-access and not yet shipped.\n" +
      "       The system WebView path (default) gives you a 445 KB binary and\n" +
      "       handles modern web standards correctly. If you hit a real\n" +
      "       rendering mismatch with desktop Chrome, open a discussion at\n" +
      "       https://github.com/popaprozac/zapp/discussions with a repro and\n" +
      "       we'll prioritize the Chromium backend for the next alpha.\n" +
      "\n" +
      "       For now: remove the `webEngine` field, or set it to \"system\"."
    );
  }
  throw new Error(
    `[zapp] webEngine: "${engine}" is not a valid value. ` +
    `Expected "system" or "chromium".`
  );
}

export async function loadConfig(root: string): Promise<ResolvedConfig> {
  const configPath = path.join(root, "zapp.config.ts");
  try {
    const mod = await import(configPath);
    // Support both `export default defineConfig({...})` and `export default {...}`
    const config = (typeof mod.default === "function" ? mod.default() : mod.default) as ZappConfig;
    validateWebEngine(config.webEngine);
    return {
      ...config,
      assetDir: config.assetDir ?? "./dist",
    };
  } catch (e) {
    if (e instanceof Error && e.message.startsWith("[zapp]")) throw e;
    return {
      name: path.basename(root),
      assetDir: "./dist",
    };
  }
}
