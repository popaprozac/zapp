// Zapp config loader — reads zapp.config.ts

import path from "node:path";
import { isIOSTarget, type BuildTarget } from "./native";

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
   * Path to a 1024×1024 PNG icon source for the iOS app icon (compiled
   * into the app's `Assets.car` via `actool`). If omitted, the CLI
   * looks, in order, for `build/ios/icon.png`, `build/icon.png`, then
   * reuses the macOS icon (`macos.icon` if it's a `.png`, else
   * `build/macos/icon.png`), then the framework default. Must be a
   * **PNG** — iOS asset catalogs don't accept `.icns`/`.iconset`; if
   * no PNG is found the iOS build proceeds without an app icon.
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

/**
 * Engine identifiers that support AOT bytecode pre-compilation.
 * Workers using these engines may set `bytecode: true` to ship a
 * pre-compiled artifact (`.zbc` for zjs, comparable for bare-hermes
 * once that path lands). Workers on other engines may not set
 * `bytecode` — the TypeScript discriminated union below enforces this.
 */
type BytecodeCapableEngine = "zjs" | "bare-hermes";

/**
 * Engine identifiers that do NOT support bytecode pre-compilation
 * today. Setting `bytecode: true` on these is a type error.
 */
type ScriptOnlyEngine = "bare-jsc" | "bare-v8" | "bare-quickjs" | "bare-mqjs";

/** Union of all engine identifiers. */
export type WorkerEngineName = BytecodeCapableEngine | ScriptOnlyEngine;

interface HeadlessWorkerConfigBase {
  /** Script path (same as the bare-string form). */
  script: string;
  /** Display label shown in logs and Workers.list(). Optional. */
  name?: string;
  /** Optional restart policy. Omit / `false` to disable auto-restart. */
  restart?: RestartPolicy | false;
}

/**
 * Per-worker config — `engine` + `bytecode` are jointly type-narrowed.
 *
 * **Engine selection:**
 *
 * - `"zjs"` (recommended default) — Zapp's first-party engine
 *   (popaprozac/zjs). Cross-platform, ~1 MB lib, iOS-friendly (no JIT
 *   requirement). Direct value-marshalling host bridge — skips the
 *   JS-side `JSON.stringify` other engines pay on `Services.invokeSync`.
 *   Web APIs (fetch, WebSocket) ship with zjs's runtime layer as it
 *   matures.
 * - `"bare-jsc"` — almost-equal recommendation on macOS. JIT via the
 *   system JSC framework (zero engine bundle cost on Apple) at the
 *   price of less streamlined web APIs — you opt into bare-* packages
 *   à la carte (`bare-fetch`, `bare-ws`, …).
 * - `"bare-v8"` — JIT for Windows / Linux. ~30 MB bundle increase,
 *   only worth it for JIT-heavy workloads.
 * - `"bare-quickjs"` / `"bare-mqjs"` / `"bare-hermes"` — niche bare
 *   variants. Use when you specifically need that engine's perf or
 *   feature profile; otherwise prefer zjs.
 *
 * **Bytecode option:**
 *
 * Only valid on engines that ship an AOT bytecode pipeline (`"zjs"`,
 * `"bare-hermes"`). When `bytecode: true`, the CLI runs `zjs compile`
 * (or the engine's equivalent) on the Vite-bundled .mjs after the
 * build pipeline and ships the result as the worker artifact. The
 * engine loads via parse-free dispatch — faster cold start (matters
 * most on iOS where JIT is gated), smaller embedded asset. Setting
 * `bytecode: true` with `engine: "bare-jsc"` (or any non-bytecode
 * engine) is a TypeScript error.
 *
 * **Fallback chain when an engine isn't compiled in:** the resolver
 * logs the downgrade and tries
 * `zjs > bare-jsc > bare-v8 > bare-hermes > bare-quickjs > bare-mqjs`.
 */
export type HeadlessWorkerConfig =
  | (HeadlessWorkerConfigBase & {
      engine?: BytecodeCapableEngine;
      /**
       * Pre-compile the worker bundle to bytecode at build time. Only
       * valid for `engine: "zjs"` / `"bare-hermes"`. Defaults to `false`.
       */
      bytecode?: boolean;
    })
  | (HeadlessWorkerConfigBase & {
      engine: ScriptOnlyEngine;
      /** This engine does not support bytecode pre-compilation. */
      bytecode?: never;
    });

/**
 * High-level worker capability identifiers. Each maps (via the
 * `WORKER_MODULE_CAPABILITIES` registry in this file) to the
 * underlying bare-* packages a project must install and the
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

/**
 * Webview-engine preferences. Each field maps to a single underlying
 * setting on the platform's webview (WKWebView on Apple, WebView2 on
 * Windows, WebKitGTK on Linux). When a field is unset the platform's
 * default is preserved — so users only need to declare the toggles
 * they care about.
 *
 * Windows / Linux mapping lands once those platforms reach feature parity.
 * Fields that don't map cleanly (or differ in semantics) on non-Apple
 * platforms will be documented per-field.
 */
export interface WebviewPreferences {
  /**
   * Allow HTML5 `<video>` / `<audio>` to autoplay without a user gesture.
   *
   * - Apple: maps to `WKWebViewConfiguration.mediaTypesRequiringUserActionForPlayback`
   *   — set to `WKAudiovisualMediaTypeNone` when `true`, left at the
   *   platform default (`all`, gesture required) otherwise.
   *
   * Useful for: media players, dashboards, ambient displays. Avoid in
   * apps that embed third-party HTML — Safari's gesture requirement is
   * an anti-UX-abuse default for a reason.
   *
   * @default false (platform default — gesture required)
   */
  autoplayWithoutUserGesture?: boolean;

  /**
   * Whether the webview shows two-finger swipe-back / swipe-forward to
   * navigate the in-webview history (the same gesture Safari uses).
   *
   * - Apple: maps to `WKWebView.allowsBackForwardNavigationGestures`.
   *   Defaults to `false` on WKWebView (unlike Safari).
   *
   * Most Zapp apps want this off — they're single-page app shells where
   * "back" doesn't have a meaningful in-app interpretation. Browser-
   * shaped tools (docs viewers, in-app help) may want it on.
   *
   * @default false (platform default for WKWebView)
   */
  backForwardNavigationGestures?: boolean;

  /**
   * Whether the user can select text inside the webview. Disabling this
   * removes the system text-selection UI (copy, look up, share menu)
   * for kiosk / display-only screens.
   *
   * - Apple: maps to `WKPreferences.isTextInteractionEnabled`
   *   (macOS 11+ / iOS 14.5+). Default is `true`. On older OS versions
   *   the setter is a no-op (KVC-set via the legacy private key).
   *
   * @default true (platform default — selection enabled)
   */
  textInteractionEnabled?: boolean;

  /**
   * Minimum font size the renderer will lay out, in CSS pixels. Smaller
   * font-size declarations get clamped to this value.
   *
   * - Apple: maps to `WKPreferences.minimumFontSize`. Default `0` (no
   *   floor). Set to e.g. `14` for an accessibility floor or a kiosk
   *   that needs guaranteed readability at arm's length.
   *
   * Set to `0` or omit to disable (no floor).
   *
   * @default 0 (no floor)
   */
  minimumFontSize?: number;
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
  /**
   * Worker capabilities to enable. Each entry is a high-level
   * capability name (e.g. `"fetch"`, `"websocket"`, `"fs"`) — the
   * CLI maps it to the underlying bare-* package(s), verifies
   * install, and auto-prepends the matching
   * `@zappdev/runtime/worker-globals/<subpath>` import so the
   * global API (`fetch`, `WebSocket`, etc.) is available in every
   * worker without per-worker boilerplate.
   *
   * On bare engines, the package's native bindings (`binding.c`)
   * are also auto-compiled into `libbare_modules.a` via the
   * side-cmake overlay (see `ensureUserBareModulesCompiled`).
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

  /**
   * Webview-engine preferences applied at WKWebView / WebView2 / WebKitGTK
   * construction time. Every field is optional — unset fields keep the
   * platform default. macOS + iOS share the same WKWebView code path
   * and respect all fields below; Windows / Linux land later.
   *
   * @example
   * ```ts
   * webviewPreferences: {
   *   autoplayWithoutUserGesture: true,    // media-player / dashboard apps
   *   backForwardNavigationGestures: false, // app-shell, not a browser
   *   textInteractionEnabled: false,        // kiosk / display-only screens
   *   minimumFontSize: 14,                  // a11y floor
   * }
   * ```
   */
  webviewPreferences?: WebviewPreferences;

  /**
   * Extra native source files to compile into the app binary. Use this
   * to ship a custom ObjC service (`.m`), Win32 helper (`.c`), or any
   * other native module that the framework's own platform plumbing
   * doesn't already include.
   *
   * Each path is resolved relative to the project root and forwarded
   * to the platform's cflags line in `.zapp/zapp_platform.zc`. You
   * still need to declare the service in Zen-C (typically
   * `zapp/app.zc` calling `app.service.add("name", c_handler)` plus
   * an `extern fn c_handler(...)` declaration).
   *
   * Either a single list (applied on every platform that compiles it)
   * or a per-platform map. Per-platform is the usual case — ObjC
   * sources only make sense on Apple, COM/Win32 sources only on
   * Windows.
   *
   * @example
   * ```ts
   * // ObjC service on macOS only
   * nativeSources: { macos: ["src/native/MyService.m"] }
   *
   * // Cross-platform C helper
   * nativeSources: ["src/native/helper.c"]
   * ```
   *
   * @deprecated use `native.sources`
   */
  nativeSources?: PlatformValue<string[]>;

  /**
   * Additional system frameworks to link into the app binary, beyond
   * the framework-internal set Zapp already pulls (Cocoa / WebKit /
   * JavaScriptCore / UserNotifications / Carbon / Foundation / …).
   *
   * Names are passed straight to `clang -framework`. No-op on Windows
   * (frameworks are Apple-specific); use `extraLinkFlags.windows` for
   * `-l<name>` on that platform.
   *
   * @example
   * ```ts
   * // App uses Metal on Apple, nothing extra on Windows.
   * extraFrameworks: { macos: ["Metal"], ios: ["Metal"] }
   * ```
   *
   * @deprecated use `native.frameworks`
   */
  extraFrameworks?: PlatformValue<string[]>;

  /**
   * Extra raw link flags appended to the platform's `//> link:` line.
   * Use for `-l<name>` libraries the framework doesn't pull, custom
   * search paths (`-L/path`), or platform-specific link-time options.
   *
   * Per-platform is the usual case — `-l` syntax is the same shape on
   * Apple and Linux but the library names differ.
   *
   * @example
   * ```ts
   * extraLinkFlags: {
   *   macos:   ["-lsqlite3"],
   *   windows: ["-lws2_32"],
   * }
   * ```
   *
   * @deprecated use `native.linkFlags`
   */
  extraLinkFlags?: PlatformValue<string[]>;

  /**
   * Native build extras — the Tauri-style escape hatch for linking system
   * frameworks, raw linker flags, and extra native source files. Each value is
   * either an array (all targets) or a per-platform map (PlatformValue).
   *
   * This grouped block supersedes the flat `extraFrameworks` /
   * `extraLinkFlags` / `nativeSources` fields. Both are still honored and
   * merged (grouped first, then flat, de-duplicated) via `resolveNative`.
   *
   * @example
   * ```ts
   * native: {
   *   frameworks: { macos: ["CoreLocation"], ios: ["CoreLocation"] },
   *   linkFlags:  { macos: ["-lsqlite3"], windows: ["-lws2_32"] },
   *   sources:    { macos: ["src/native/MyService.m"] },
   * }
   * ```
   */
  native?: {
    frameworks?: PlatformValue<string[]>;
    linkFlags?: PlatformValue<string[]>;
    sources?: PlatformValue<string[]>;
  };
}

/**
 * Generic helper for fields that can either be applied on every
 * platform (provide just the value) or scoped per-platform (provide
 * the map). The generator normalises both shapes to a per-platform
 * lookup before emitting build directives.
 */
export type PlatformValue<T> =
  | T
  | {
      macos?:   T;
      ios?:     T;
      windows?: T;
    };

/**
 * Normalise a `PlatformValue<T[]>` into a flat array of entries for a
 * given target. Returns `[]` if nothing is configured for that target.
 * Concatenating array forms across platforms isn't supported — users
 * either declare cross-platform (raw `T[]`) or per-platform (map);
 * mixing isn't a use case we've seen.
 */
export function resolvePlatformValue<T>(
  v: PlatformValue<T[]> | undefined,
  target: "macos" | "ios" | "windows",
): T[] {
  if (!v) return [];
  if (Array.isArray(v)) return v;
  return v[target] ?? [];
}

/**
 * Merge the grouped `native:` block with the deprecated flat fields
 * (`extraFrameworks` / `extraLinkFlags` / `nativeSources`), resolved for
 * `target`. Grouped values come first, then flat, de-duplicated (order
 * preserved). Both iOS subtargets collapse to the `ios` map key — the same
 * bucket `resolvePlatformValue` uses elsewhere in the build.
 */
export function resolveNative(
  config: ZappConfig,
  target: BuildTarget,
): { frameworks: string[]; linkFlags: string[]; sources: string[] } {
  // Collapse BuildTarget → the narrow per-platform bucket key that
  // resolvePlatformValue reads (both iOS subtargets share the "ios" set).
  const platformKey: "macos" | "ios" | "windows" =
    target === "macos"   ? "macos"
    : isIOSTarget(target) ? "ios"
    : "windows";
  const dedupe = (xs: string[]) => [...new Set(xs)];
  const merge = (
    grouped: PlatformValue<string[]> | undefined,
    flat: PlatformValue<string[]> | undefined,
  ) => dedupe([
    ...resolvePlatformValue(grouped, platformKey),
    ...resolvePlatformValue(flat, platformKey),
  ]);
  return {
    frameworks: merge(config.native?.frameworks, config.extraFrameworks),
    linkFlags: merge(config.native?.linkFlags, config.extraLinkFlags),
    sources: merge(config.native?.sources, config.nativeSources),
  };
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
// Validate the native: block — each of frameworks/linkFlags/sources must be a
// string[] or a per-platform map of string[]. Throws a clear error otherwise.
export function validateNative(config: ZappConfig): void {
  const n = config.native;
  if (!n) return;
  const checkList = (v: unknown, where: string) => {
    if (!Array.isArray(v)) throw new Error(`[zapp] ${where} must be a string[] (got ${typeof v})`);
    for (const item of v) {
      if (typeof item !== "string") throw new Error(`[zapp] ${where} entries must be strings (got ${typeof item})`);
    }
  };
  const checkField = (v: unknown, name: string) => {
    if (v === undefined) return;
    if (Array.isArray(v)) { checkList(v, `native.${name}`); return; }
    if (v && typeof v === "object") {
      for (const [plat, list] of Object.entries(v as Record<string, unknown>)) {
        checkList(list, `native.${name}.${plat}`);
      }
      return;
    }
    throw new Error(`[zapp] native.${name} must be a string[] or a per-platform map (got ${typeof v})`);
  };
  checkField(n.frameworks, "frameworks");
  checkField(n.linkFlags, "linkFlags");
  checkField(n.sources, "sources");
}

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

// Removed engines — surface a clean error before TypeScript's narrowed
// union catches the mistake at compile time. Catches untyped config
// loaders, JSON-deserialized configs, and the occasional copy-paste
// from old example code or chat-bot output.
function rejectRemovedEngines(config: ZappConfig): void {
  const removed = new Set(["jsc", "txiki"]);
  const headless = config.headless ?? {};
  for (const [id, entry] of Object.entries(headless)) {
    if (typeof entry === "object" && entry !== null && "engine" in entry) {
      const engine = (entry as { engine?: string }).engine;
      if (engine && removed.has(engine)) {
        throw new Error(
          `[zapp] headless worker "${id}" specifies engine: "${engine}", ` +
          `which has been removed. Use "zjs" (cross-platform, default) ` +
          `or "bare-jsc" (macOS JIT). See docs/engines.md.`
        );
      }
    }
  }
}

export async function loadConfig(root: string): Promise<ResolvedConfig> {
  const configPath = path.join(root, "zapp.config.ts");
  try {
    const mod = await import(configPath);
    // Support both `export default defineConfig({...})` and `export default {...}`
    const config = (typeof mod.default === "function" ? mod.default() : mod.default) as ZappConfig;
    validateWebEngine(config.webEngine);
    rejectRemovedEngines(config);
    validateNative(config);
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
