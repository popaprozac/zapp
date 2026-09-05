// Zapp config loader — reads zapp.config.ts

import path from "node:path";
import { existsSync } from "node:fs";
import { mkdir, writeFile } from "node:fs/promises";
// Type-only import — erased at compile time. config.ts is bundled standalone
// by the cli prepack (dist/config.js backs the `@zappdev/cli/config` export
// for user zapp.config.ts files); a VALUE import of ./native would drag the
// entire build machinery (incl. babel's dynamic requires) into that bundle
// and break `npm pack`.
import type { BuildTarget } from "./build-target";
import type { ZappPermission } from "./permissions";
import {
  isPermissionAllowed,
  resolvePermissions,
  validatePermissions,
} from "./permissions";
export type { ZappPermission };

export interface MacOSConfig {
  /**
   * Path to an icon. Supported formats: `.icon` (Icon Composer, best for
   * macOS 26+), `.icns`, `.iconset`, `.png` (1024×1024). Path is relative
   * to the project root or absolute.
   *
   * If omitted, the CLI looks for `build/macos/icon.{icon,icns,iconset,png}`
   * in the project. Zapp does not apply framework branding by default.
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
   * `build/macos/icon.png`). Must be a **PNG** — iOS asset catalogs don't
   * accept `.icns`/`.iconset`; if no PNG is found the iOS build proceeds
   * without an app icon.
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

/** Checked Z protocol used to generate typed worker command/message facades. */
export interface ApplicationWorkerProtocolConfig {
  /** Z source module relative to the application root. */
  module: string;
  /** Exported WorkerProtocol<Command, Message> alias in that module. */
  type: string;
}

interface ApplicationWorkerConfigBase {
  /** Script path (same as the bare-string form). */
  script: string;
  /** Display label shown in logs and Workers.list(). Optional. */
  name?: string;
  /** Trusted native authority profiles frozen when this worker is created. */
  capabilities?: string[];
  /** Optional restart policy. Omit / `false` to disable auto-restart. */
  restart?: RestartPolicy | false;
  /** Optional checked command/message protocol authored in ordinary Z types. */
  protocol?: ApplicationWorkerProtocolConfig;
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
export type ApplicationWorkerConfig =
  | (ApplicationWorkerConfigBase & {
      engine?: BytecodeCapableEngine;
      /**
       * Pre-compile the worker bundle to bytecode at build time. Only
       * valid for `engine: "zjs"` / `"bare-hermes"`. Defaults to `false`.
       */
      bytecode?: boolean;
    })
  | (ApplicationWorkerConfigBase & {
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

export interface ApplicationConfig {
  /** Human-readable product name. */
  name: string;
  /** Reverse-DNS application identifier. */
  identifier?: string;
  /** Application version embedded into native packages. */
  version?: string;
  /** Prevent multiple application instances where the platform supports it. */
  singleInstance?: boolean;
  /** System-visible URL schemes, without `://`. */
  deepLinks?: string[];
}

export interface FrontendConfig {
  /** Directory containing the built frontend. @default "./dist" */
  assets?: string;
  /** Development-server settings used by `zapp dev`. */
  devServer?: {
    /** @default 5173 */
    port?: number;
  };
  /** Brotli-compress eligible embedded assets in production. @default true */
  compressAssets?: boolean;
}

export interface WebviewInjectProfile {
  /** CSS files installed at document start, in declaration order. */
  styles?: string[];
  /** TypeScript or JavaScript files installed after the Zapp bridge. */
  documentStart?: string[];
  /** TypeScript or JavaScript files installed at WebView document end. */
  documentEnd?: string[];
}

export interface WebviewConfig {
  /** Main WebView engine. The system engine remains the default. */
  engine?: PlatformValue<WebEngine>;
  /** URL schemes handled inside Zapp WebViews rather than by the OS. */
  protocols?: string[];
  /** Engine preferences applied when each WebView is constructed. */
  preferences?: WebviewPreferences;
  /** Trusted build-time content profiles selected per WindowOptions.inject. */
  inject?: Record<string, WebviewInjectProfile>;
}

export interface WorkersConfig {
  /** Workers started after services and stopped before services, keyed by ID. */
  application?: Record<string, string | ApplicationWorkerConfig>;
  /**
   * Provisional web-compatible runtime modules installed into first-party
   * workers. This vocabulary remains under review with the ZJS rewrite.
   */
  modules?: WorkerModuleId[];
}

export interface SecurityConfig {
  /** Exhaustive native-capability allowlist when present. */
  permissions?: ZappPermission[];
  /** Named, trusted grants selected by native WindowOptions. */
  capabilities?: Record<string, CapabilityProfileConfig>;
  /** Named, immutable navigation ceilings selected by trusted windows. */
  navigation?: Record<string, NavigationProfileConfig>;
  /** Filesystem access and persisted dialog-grant policy. */
  filesystem?: FsConfig;
}

export interface NavigationProfileConfig {
  /** Origins that may load inside the WebView. `self` is the logical app origin. */
  navigate?: string[];
  /** URL schemes that trusted native code may later open through the system. */
  openExternal?: string[];
}

export interface CapabilityProfileConfig {
  /** Framework permissions granted to windows using this profile. */
  permissions?: ZappPermission[];
  /** Registered Z services or exact `service.method` selectors. */
  services?: string[];
  /** Configured application workers this profile may address. */
  workers?: string[];
}

export interface NativeConfig {
  /** Additional system frameworks linked into the application. */
  frameworks?: PlatformValue<string[]>;
  /** Explicit linker flags for native dependencies and search paths. */
  linkFlags?: PlatformValue<string[]>;
  /** Additional C, C++, Objective-C, or other supported native sources. */
  sources?: PlatformValue<string[]>;
}

export interface TargetConfig {
  /** macOS packaging, signing, entitlement, and deployment settings. */
  macOS?: MacOSConfig;
  /** iOS packaging, signing, capability, and deployment settings. */
  iOS?: IOSConfig;
}

/** Ergonomic, serializable authoring surface for `zapp.config.ts`. */
export interface ZappConfig {
  application: ApplicationConfig;
  frontend?: FrontendConfig;
  webview?: WebviewConfig;
  workers?: WorkersConfig;
  security?: SecurityConfig;
  native?: NativeConfig;
  targets?: TargetConfig;
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
      macOS?:   T;
      iOS?:     T;
      windows?: T;
      linux?:   T;
    };

/** Which engine renders the WebView content: system WebView or bundled CEF/Chromium. */
export type WebEngine = "system" | "chromium";

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
  const key = target === "macos" ? "macOS" : target === "ios" ? "iOS" : "windows";
  return v[key] ?? [];
}

export function resolveNative(
  config: { native?: NativeConfig },
  target: BuildTarget,
): { frameworks: string[]; linkFlags: string[]; sources: string[] } {
  // Collapse BuildTarget → the narrow per-platform bucket key that
  // resolvePlatformValue reads (both iOS subtargets share the "ios" set).
  const platformKey: "macos" | "ios" | "windows" =
    target === "macos" ? "macos"
    // Inlined isIOSTarget (./native) — see the type-only import note at top.
    : (target === "ios-simulator" || target === "ios-device") ? "ios"
    : "windows";
  return {
    frameworks: [...new Set(resolvePlatformValue(config.native?.frameworks, platformKey))],
    linkFlags: [...new Set(resolvePlatformValue(config.native?.linkFlags, platformKey))],
    sources: [...new Set(resolvePlatformValue(config.native?.sources, platformKey))],
  };
}

/** Normalized contract consumed by build, packaging, Vite, and native emission. */
export interface ResolvedConfig {
  name: string;
  identifier: string;
  version: string;
  assetDir: string;
  devPort?: number;
  compressAssets?: boolean;
  applicationWorkers?: Record<string, string | ApplicationWorkerConfig>;
  workerModules?: WorkerModuleId[];
  deepLinkSchemes?: string[];
  protocols?: string[];
  singleInstance?: boolean;
  fs?: FsConfig;
  permissions?: ZappPermission[];
  capabilityProfiles?: Record<string, CapabilityProfileConfig>;
  navigationProfiles?: Record<string, NavigationProfileConfig>;
  macos?: MacOSConfig;
  ios?: IOSConfig;
  webEngine?: PlatformValue<WebEngine>;
  webviewPreferences?: WebviewPreferences;
  webviewInject?: Record<string, WebviewInjectProfile>;
  native?: NativeConfig;
}

export type ZappConfigCommand = "dev" | "build" | "package";
export type ZappConfigMode = "development" | "production";
export type ZappTargetOS = "macos" | "ios" | "windows" | "linux";
export type ZappTargetArch = "arm64" | "x64";
export type ZappTargetEnvironment = "desktop" | "simulator" | "device";

export interface ZappConfigContext {
  command: ZappConfigCommand;
  mode: ZappConfigMode;
  target: {
    os: ZappTargetOS;
    arch: ZappTargetArch;
    environment: ZappTargetEnvironment;
  };
  /** Absolute project root. Useful for resolving imported build inputs. */
  root: string;
}

export type ZappConfigFactory = (
  context: ZappConfigContext,
) => ZappConfig | Promise<ZappConfig>;

export type ZappConfigDefinition = ZappConfig | ZappConfigFactory;

export function defineConfig(config: ZappConfig): ZappConfig;
export function defineConfig(factory: ZappConfigFactory): ZappConfigFactory;
export function defineConfig(
  definition: ZappConfigDefinition,
): ZappConfigDefinition {
  return definition;
}

export function createConfigContext(
  root: string,
  command: ZappConfigCommand,
  target: BuildTarget,
): ZappConfigContext {
  const os: ZappTargetOS = target === "macos" ? "macos"
    : target === "windows" ? "windows"
    : "ios";
  const environment: ZappTargetEnvironment = target === "ios-simulator"
    ? "simulator"
    : target === "ios-device" ? "device"
    : "desktop";
  return {
    command,
    mode: command === "dev" ? "development" : "production",
    target: {
      os,
      arch: process.arch === "arm64" ? "arm64" : "x64",
      environment,
    },
    root: path.resolve(root),
  };
}

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
        if (!new Set(["macOS", "iOS", "windows", "linux"]).has(plat)) {
          throw new Error(
            `[zapp] native.${name}.${plat} is not a valid target; ` +
            `use macOS, iOS, windows, or linux`,
          );
        }
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

// Validate the webEngine field shape/values. Pure: throws on a bad value in
// either the string or the per-platform map form. Target-specific notices
// (early-access, unsupported-platform) are emitted at build time (native.ts),
// where the build target is known.
export function validateWebEngine(engine?: PlatformValue<WebEngine>): void {
  if (engine === undefined) return;
  const checkValue = (v: unknown, where: string) => {
    if (v === undefined) return;
    if (v !== "system" && v !== "chromium") {
      throw new Error(
        `[zapp] webview.engine${where}: "${String(v)}" is not a valid value. ` +
        `Use "system" or "chromium".`,
      );
    }
  };
  if (typeof engine === "object" && engine !== null) {
    const m = engine as { macOS?: unknown; iOS?: unknown; windows?: unknown; linux?: unknown };
    for (const key of Object.keys(m)) {
      if (!new Set(["macOS", "iOS", "windows", "linux"]).has(key)) {
        throw new Error(
          `[zapp] webview.engine.${key} is not a valid target; ` +
          `use macOS, iOS, windows, or linux`,
        );
      }
    }
    checkValue(m.macOS, ".macOS");
    checkValue(m.iOS, ".iOS");
    checkValue(m.windows, ".windows");
    checkValue(m.linux, ".linux");
  } else {
    checkValue(engine, "");
  }
}

export function validateWebviewInject(
  inject?: Record<string, WebviewInjectProfile>,
): void {
  if (inject === undefined) return;
  if (inject === null || typeof inject !== "object" || Array.isArray(inject)) {
    throw new Error("[zapp] webview.inject must be an object keyed by profile name");
  }
  const profileName = /^[A-Za-z][A-Za-z0-9._-]*$/;
  const allowedKeys = new Set(["styles", "documentStart", "documentEnd"]);
  for (const [name, profile] of Object.entries(inject)) {
    if (!profileName.test(name)) {
      throw new Error(
        `[zapp] webview.inject profile ${JSON.stringify(name)} must start with a letter ` +
        "and contain only letters, digits, '.', '_', or '-'",
      );
    }
    if (profile === null || typeof profile !== "object" || Array.isArray(profile)) {
      throw new Error(`[zapp] webview.inject.${name} must be an object`);
    }
    for (const key of Object.keys(profile)) {
      if (!allowedKeys.has(key)) {
        throw new Error(
          `[zapp] webview.inject.${name}.${key} is unknown; ` +
          "use styles, documentStart, or documentEnd",
        );
      }
    }
    let entryCount = 0;
    for (const key of allowedKeys) {
      const value = profile[key as keyof WebviewInjectProfile];
      if (value === undefined) continue;
      if (!Array.isArray(value)) {
        throw new Error(`[zapp] webview.inject.${name}.${key} must be a string[]`);
      }
      const seen = new Set<string>();
      for (const entry of value) {
        if (typeof entry !== "string" || entry.trim().length === 0) {
          throw new Error(
            `[zapp] webview.inject.${name}.${key} entries must be non-empty paths`,
          );
        }
        if (path.isAbsolute(entry) || entry.split(/[\\/]+/).includes("..")) {
          throw new Error(
            `[zapp] webview.inject.${name}.${key} path ${JSON.stringify(entry)} ` +
            "must stay relative to the application root",
          );
        }
        if (seen.has(entry)) {
          throw new Error(
            `[zapp] webview.inject.${name}.${key} repeats ${JSON.stringify(entry)}`,
          );
        }
        seen.add(entry);
        entryCount += 1;
      }
    }
    if (entryCount === 0) {
      throw new Error(`[zapp] webview.inject.${name} must declare at least one file`);
    }
  }
}

function canonicalNavigationOrigin(value: string): string {
  const parsed = new URL(value);
  if (
    (parsed.protocol !== "http:" && parsed.protocol !== "https:")
    || parsed.username.length > 0
    || parsed.password.length > 0
    || parsed.pathname !== "/"
    || parsed.search.length > 0
    || parsed.hash.length > 0
  ) {
    throw new Error("expected an HTTP(S) origin without credentials, path, query, or fragment");
  }
  return parsed.origin;
}

export function validateNavigationProfiles(
  profiles: Record<string, NavigationProfileConfig> | undefined,
): void {
  if (profiles === undefined) return;
  if (profiles === null || typeof profiles !== "object" || Array.isArray(profiles)) {
    throw new Error("[zapp] security.navigation must be an object keyed by profile name");
  }
  if (!("default" in profiles)) {
    throw new Error('[zapp] security.navigation must declare a "default" profile');
  }
  const profileName = /^[A-Za-z][A-Za-z0-9._-]*$/;
  const externalScheme = /^[A-Za-z][A-Za-z0-9+.-]*:$/;
  const allowedKeys = new Set(["navigate", "openExternal"]);
  for (const [name, profile] of Object.entries(profiles)) {
    if (!profileName.test(name)) {
      throw new Error(
        `[zapp] security.navigation profile ${JSON.stringify(name)} must start with a letter ` +
        "and contain only letters, digits, '.', '_', or '-'",
      );
    }
    if (profile === null || typeof profile !== "object" || Array.isArray(profile)) {
      throw new Error(`[zapp] security.navigation.${name} must be an object`);
    }
    for (const key of Object.keys(profile)) {
      if (!allowedKeys.has(key)) {
        throw new Error(
          `[zapp] security.navigation.${name}.${key} is unknown; ` +
          "use navigate or openExternal",
        );
      }
    }
    for (const key of allowedKeys) {
      const values = profile[key as keyof NavigationProfileConfig];
      if (values === undefined) continue;
      if (!Array.isArray(values)) {
        throw new Error(`[zapp] security.navigation.${name}.${key} must be a string[]`);
      }
      const seen = new Set<string>();
      for (const value of values) {
        if (typeof value !== "string" || value.trim().length === 0) {
          throw new Error(
            `[zapp] security.navigation.${name}.${key} entries must be non-empty strings`,
          );
        }
        let canonical: string;
        if (key === "navigate") {
          if (value === "self") canonical = value;
          else {
            try {
              canonical = canonicalNavigationOrigin(value);
            } catch {
              throw new Error(
                `[zapp] security.navigation.${name}.navigate entry ${JSON.stringify(value)} ` +
                "must be \"self\" or an HTTP(S) origin without a path",
              );
            }
          }
        } else {
          if (!externalScheme.test(value)) {
            throw new Error(
              `[zapp] security.navigation.${name}.openExternal entry ${JSON.stringify(value)} ` +
              'must be a URL scheme ending in ":"',
            );
          }
          canonical = value.toLowerCase();
        }
        if (seen.has(canonical)) {
          throw new Error(
            `[zapp] security.navigation.${name}.${key} repeats ${JSON.stringify(value)}`,
          );
        }
        seen.add(canonical);
      }
    }
  }
}

export function validateCapabilityProfiles(
  profiles: Record<string, CapabilityProfileConfig> | undefined,
  globalPermissions?: ZappPermission[],
): void {
  if (profiles === undefined) return;
  if (profiles === null || typeof profiles !== "object" || Array.isArray(profiles)) {
    throw new Error("[zapp] security.capabilities must be an object keyed by profile name");
  }
  if (!("default" in profiles)) {
    throw new Error(
      '[zapp] security.capabilities must declare a "default" profile',
    );
  }
  const profileName = /^[A-Za-z][A-Za-z0-9._-]*$/;
  const allowedKeys = new Set(["permissions", "services", "workers"]);
  const global = resolvePermissions(globalPermissions);
  for (const [name, profile] of Object.entries(profiles)) {
    if (!profileName.test(name)) {
      throw new Error(
        `[zapp] security.capabilities profile ${JSON.stringify(name)} must start with a letter ` +
        "and contain only letters, digits, '.', '_', or '-'",
      );
    }
    if (profile === null || typeof profile !== "object" || Array.isArray(profile)) {
      throw new Error(`[zapp] security.capabilities.${name} must be an object`);
    }
    for (const key of Object.keys(profile)) {
      if (!allowedKeys.has(key)) {
        throw new Error(
          `[zapp] security.capabilities.${name}.${key} is unknown; ` +
          "use permissions, services, or workers",
        );
      }
    }
    for (const key of allowedKeys) {
      const values = profile[key as keyof CapabilityProfileConfig];
      if (values === undefined) continue;
      if (!Array.isArray(values)) {
        throw new Error(`[zapp] security.capabilities.${name}.${key} must be a string[]`);
      }
      const seen = new Set<string>();
      for (const value of values) {
        if (typeof value !== "string" || value.trim().length === 0) {
          throw new Error(
            `[zapp] security.capabilities.${name}.${key} entries must be non-empty strings`,
          );
        }
        if (seen.has(value)) {
          throw new Error(
            `[zapp] security.capabilities.${name}.${key} repeats ${JSON.stringify(value)}`,
          );
        }
        seen.add(value);
      }
    }
    const permissionErrors = validatePermissions(profile.permissions);
    if (permissionErrors.length > 0) throw new Error(permissionErrors[0]);
    for (const permission of profile.permissions ?? []) {
      if (
        permission !== "window:create"
        && permission !== "menu"
        && permission !== "clipboard:read"
        && permission !== "clipboard:write"
        && permission !== "clipboard"
        && permission !== "notifications"
      ) {
        throw new Error(
          `[zapp] security.capabilities.${name} cannot grant ${JSON.stringify(permission)} yet; ` +
          'the Z-native per-window permission tier currently supports "window:create", "menu", "notifications", clipboard access, and services',
        );
      }
      if (!isPermissionAllowed(permission, global)) {
        throw new Error(
          `[zapp] security.capabilities.${name} grants ${JSON.stringify(permission)}, ` +
          "but security.permissions does not include it",
        );
      }
    }
  }
}

export function validateWorkers(
  workers: WorkersConfig | undefined,
  profiles: Record<string, CapabilityProfileConfig> | undefined,
): void {
  if (workers === undefined) {
    for (const [profileName, profile] of Object.entries(profiles ?? {})) {
      if ((profile.workers?.length ?? 0) > 0) {
        throw new Error(
          `[zapp] security.capabilities.${profileName}.workers references configured ` +
          "application workers, but workers.application is absent",
        );
      }
    }
    return;
  }
  if (workers === null || typeof workers !== "object" || Array.isArray(workers)) {
    throw new Error("[zapp] workers must be an object");
  }
  const allowedWorkerKeys = new Set(["application", "modules"]);
  for (const key of Object.keys(workers)) {
    if (!allowedWorkerKeys.has(key)) {
      throw new Error(
        `[zapp] workers.${key} is unknown; use application or modules`,
      );
    }
  }

  const modules = workers.modules;
  if (modules !== undefined) {
    if (!Array.isArray(modules)) {
      throw new Error("[zapp] workers.modules must be a string[]");
    }
    const knownModules = new Set(Object.keys(WORKER_MODULE_CAPABILITIES));
    const seenModules = new Set<string>();
    for (const module of modules) {
      if (typeof module !== "string" || !knownModules.has(module)) {
        throw new Error(
          `[zapp] workers.modules contains unknown module ${JSON.stringify(module)}`,
        );
      }
      if (seenModules.has(module)) {
        throw new Error(`[zapp] workers.modules repeats ${JSON.stringify(module)}`);
      }
      seenModules.add(module);
    }
  }

  const application = workers.application;
  if (application === undefined) {
    for (const [profileName, profile] of Object.entries(profiles ?? {})) {
      if ((profile.workers?.length ?? 0) > 0) {
        throw new Error(
          `[zapp] security.capabilities.${profileName}.workers references configured ` +
          "application workers, but workers.application is absent",
        );
      }
    }
    return;
  }
  if (
    application === null
    || typeof application !== "object"
    || Array.isArray(application)
  ) {
    throw new Error("[zapp] workers.application must be an object keyed by worker ID");
  }
  const workerId = /^[A-Za-z][A-Za-z0-9._-]*$/;
  const allowedEntryKeys = new Set([
    "script",
    "name",
    "capabilities",
    "restart",
    "engine",
    "bytecode",
    "protocol",
  ]);
  const knownProfiles = new Set(profiles ? Object.keys(profiles) : ["default"]);
  const knownWorkers = new Set(Object.keys(application));
  for (const [profileName, profile] of Object.entries(profiles ?? {})) {
    for (const id of profile.workers ?? []) {
      if (!knownWorkers.has(id)) {
        throw new Error(
          `[zapp] security.capabilities.${profileName}.workers contains unknown ` +
          `application worker ${JSON.stringify(id)}`,
        );
      }
    }
  }
  const validateRelativeSource = (description: string, source: unknown): void => {
    if (typeof source !== "string" || source.trim().length === 0) {
      throw new Error(`[zapp] ${description} must be a non-empty string`);
    }
    if (path.isAbsolute(source) || source.split(/[\\/]+/).includes("..")) {
      throw new Error(
        `[zapp] ${description} must stay relative to the application root`,
      );
    }
  };

  for (const [id, entry] of Object.entries(application)) {
    if (!workerId.test(id)) {
      throw new Error(
        `[zapp] workers.application worker ID ${JSON.stringify(id)} must start with a letter ` +
        "and contain only letters, digits, '.', '_', or '-'",
      );
    }
    if (typeof entry === "string") {
      validateRelativeSource(`workers.application.${id}.script`, entry);
      continue;
    }
    if (entry === null || typeof entry !== "object" || Array.isArray(entry)) {
      throw new Error(`[zapp] workers.application.${id} must be a script path or object`);
    }
    for (const key of Object.keys(entry)) {
      if (!allowedEntryKeys.has(key)) {
        throw new Error(`[zapp] workers.application.${id}.${key} is unknown`);
      }
    }
    validateRelativeSource(`workers.application.${id}.script`, entry.script);
    if (entry.protocol !== undefined) {
      if (
        entry.protocol === null
        || typeof entry.protocol !== "object"
        || Array.isArray(entry.protocol)
      ) {
        throw new Error(
          `[zapp] workers.application.${id}.protocol must be an object with module and type`,
        );
      }
      const protocolKeys = new Set(["module", "type"]);
      for (const key of Object.keys(entry.protocol)) {
        if (!protocolKeys.has(key)) {
          throw new Error(`[zapp] workers.application.${id}.protocol.${key} is unknown`);
        }
      }
      validateRelativeSource(
        `workers.application.${id}.protocol.module`,
        entry.protocol.module,
      );
      if (!entry.protocol.module.endsWith(".zs")) {
        throw new Error(
          `[zapp] workers.application.${id}.protocol.module must name a .zs source file`,
        );
      }
      if (
        typeof entry.protocol.type !== "string"
        || !/^[A-Za-z_][A-Za-z0-9_]*$/.test(entry.protocol.type)
      ) {
        throw new Error(
          `[zapp] workers.application.${id}.protocol.type must be a Z identifier`,
        );
      }
      if (!/^[A-Za-z_$][A-Za-z0-9_$]*$/.test(id)) {
        throw new Error(
          `[zapp] typed application worker ID ${JSON.stringify(id)} must be a Z/TypeScript identifier`,
        );
      }
    }
    if (entry.capabilities !== undefined) {
      if (!Array.isArray(entry.capabilities)) {
        throw new Error(`[zapp] workers.application.${id}.capabilities must be a string[]`);
      }
      const seenProfiles = new Set<string>();
      for (const profile of entry.capabilities) {
        if (typeof profile !== "string" || profile.trim().length === 0) {
          throw new Error(
            `[zapp] workers.application.${id}.capabilities entries must be non-empty strings`,
          );
        }
        if (!knownProfiles.has(profile)) {
          throw new Error(
            `[zapp] workers.application.${id}.capabilities references unknown ` +
            `security capability profile ${JSON.stringify(profile)}`,
          );
        }
        if (seenProfiles.has(profile)) {
          throw new Error(
            `[zapp] workers.application.${id}.capabilities repeats ${JSON.stringify(profile)}`,
          );
        }
        seenProfiles.add(profile);
      }
    }
    if (entry.restart !== undefined && entry.restart !== false) {
      if (
        entry.restart === null
        || typeof entry.restart !== "object"
        || Array.isArray(entry.restart)
      ) {
        throw new Error(
          `[zapp] workers.application.${id}.restart must be false or an object`,
        );
      }
      const restartKeys = new Set(["maxRetries", "withinMs"]);
      for (const key of Object.keys(entry.restart)) {
        if (!restartKeys.has(key)) {
          throw new Error(`[zapp] workers.application.${id}.restart.${key} is unknown`);
        }
      }
      for (const [key, value] of [
        ["maxRetries", entry.restart.maxRetries],
        ["withinMs", entry.restart.withinMs],
      ] as const) {
        if (
          value !== undefined
          && (!Number.isSafeInteger(value) || value <= 0)
        ) {
          throw new Error(
            `[zapp] workers.application.${id}.restart.${key} must be a positive safe integer`,
          );
        }
      }
    }
  }
}

// Scalar sibling of resolvePlatformValue (which is array-typed / []-defaulted):
// a bare value applies to every platform; a map is looked up per key.
function resolvePlatformScalar<T>(
  v: PlatformValue<T> | undefined,
  key: "macos" | "ios" | "windows",
  fallback: T,
): T {
  if (v === undefined) return fallback;
  if (typeof v === "object" && v !== null) {
    const authoredKey = key === "macos" ? "macOS" : key === "ios" ? "iOS" : "windows";
    return (v as { macOS?: T; iOS?: T; windows?: T })[authoredKey] ?? fallback;
  }
  return v as T; // bare value → all platforms
}

// Collapse BuildTarget → the narrow per-platform key (both iOS subtargets → "ios"),
// identical to resolveNative's collapse.
function webEnginePlatformKey(target: BuildTarget): "macos" | "ios" | "windows" {
  return target === "macos" ? "macos"
    : (target === "ios-simulator" || target === "ios-device") ? "ios"
    : "windows";
}

// Resolve the requested webEngine for a target. PURE. Default "system".
export function resolveWebEngine(
  config: { webEngine?: PlatformValue<WebEngine> },
  target: BuildTarget,
): WebEngine {
  return resolvePlatformScalar<WebEngine>(config.webEngine, webEnginePlatformKey(target), "system");
}

// Which targets have a real CEF build today. macOS-only for now (Windows uses
// WebView2 = Chromium; Linux CEF is future).
export function platformSupportsChromium(target: BuildTarget): boolean {
  return target === "macos";
}

// The engine a build should actually use, plus whether "chromium" was downgraded
// to "system" because the target has no CEF build. PURE (no logging — the caller
// emits the warning so this stays unit-testable).
export function resolveWebEngineForBuild(
  config: { webEngine?: PlatformValue<WebEngine> },
  target: BuildTarget,
): { engine: WebEngine; downgraded: boolean } {
  const requested = resolveWebEngine(config, target);
  if (requested === "chromium" && !platformSupportsChromium(target)) {
    return { engine: "system", downgraded: true };
  }
  return { engine: requested, downgraded: false };
}

// Removed engines — surface a clean error before TypeScript's narrowed
// union catches the mistake at compile time. Catches untyped config
// loaders, JSON-deserialized configs, and the occasional copy-paste
// from old example code or chat-bot output.
function rejectRemovedEngines(config: ZappConfig): void {
  const removed = new Set(["jsc", "txiki"]);
  const workers = config.workers?.application ?? {};
  for (const [id, entry] of Object.entries(workers)) {
    if (typeof entry === "object" && entry !== null && "engine" in entry) {
      const engine = (entry as { engine?: string }).engine;
      if (engine && removed.has(engine)) {
        throw new Error(
          `[zapp] application worker "${id}" specifies engine: "${engine}", ` +
          `which has been removed. Use "zjs" (cross-platform, default) ` +
          `or "bare-jsc" (macOS JIT). See docs/engines.md.`
        );
      }
    }
  }
}

// zjs Windows support gates on the vendor checkout being present —
// vendor/zjs now ships Windows parity (libuv loop + winhttp/ws2_32
// platform layer), so when the submodule/junction is initialized the
// engine passes through and builds. On machines WITHOUT vendor/zjs,
// configs that pin `engine: "zjs"` still get the platform's default
// bare engine instead of a cryptic `zjs.h: No such file` compile
// error, so the same zapp.config.ts keeps working everywhere.
let _zjsSubstituteWarned = false;
async function substituteZjsOnWindows(config: ZappConfig): Promise<void> {
  const { detectTarget, defaultBareEngine } = await import("./native");
  const target = detectTarget();
  if (target !== "windows") return;
  // Available when the vendor checkout has the library entry — the
  // build-config zjs block compiles the embed archive from it on
  // demand. Mirrored in vite/src/index.ts effectiveEngine.
  const { resolveVendorDir } = await import("./paths");
  const { existsSync } = await import("node:fs");
  if (existsSync(path.join(resolveVendorDir(), "zjs", "src", "lib.zc"))) return;
  const fallback = `bare-${defaultBareEngine(target)}` as const;
  const substituted: string[] = [];
  for (const [id, entry] of Object.entries(config.workers?.application ?? {})) {
    if (typeof entry !== "object" || entry === null) continue;
    const e = entry as { engine?: string; bytecode?: boolean };
    if (e.engine !== "zjs") continue;
    e.engine = fallback;
    if (e.bytecode) delete e.bytecode; // zjs-only feature
    substituted.push(id);
  }
  if (substituted.length > 0 && !_zjsSubstituteWarned) {
    _zjsSubstituteWarned = true;
    const { clogError } = await import("./log");
    clogError(
      `engine "zjs" is not yet available on Windows — substituting "${fallback}" ` +
      `for application worker(s): ${substituted.join(", ")} (bytecode disabled where set). ` +
      `zjs Windows support is tracked separately; this substitution will be removed when it lands.`
    );
  }
}

function serializableConfigClone(config: ZappConfig): ZappConfig {
  const active = new WeakSet<object>();
  const inspect = (value: unknown, location: string, inArray = false): void => {
    if (value === undefined) {
      if (inArray) {
        throw new Error(`[zapp] ${location} cannot be undefined inside an array`);
      }
      return;
    }
    if (value === null || typeof value === "string" || typeof value === "boolean") return;
    if (typeof value === "number") {
      if (!Number.isFinite(value)) {
        throw new Error(`[zapp] ${location} must be a finite number`);
      }
      return;
    }
    if (typeof value === "function" || typeof value === "symbol" || typeof value === "bigint") {
      throw new Error(
        `[zapp] ${location} must be serializable; received ${typeof value}`,
      );
    }
    if (typeof value !== "object") return;
    if (active.has(value)) {
      throw new Error(`[zapp] ${location} contains a circular reference`);
    }
    active.add(value);
    if (Array.isArray(value)) {
      value.forEach((entry, index) => inspect(entry, `${location}[${index}]`, true));
    } else {
      const prototype = Object.getPrototypeOf(value);
      if (prototype !== Object.prototype && prototype !== null) {
        const name = prototype?.constructor?.name ?? "non-plain object";
        throw new Error(
          `[zapp] ${location} must be a plain serializable object; received ${name}`,
        );
      }
      for (const [key, entry] of Object.entries(value)) {
        inspect(entry, `${location}.${key}`);
      }
    }
    active.delete(value);
  };
  inspect(config, "config");
  return JSON.parse(JSON.stringify(config)) as ZappConfig;
}

function normalizeConfig(config: ZappConfig): ResolvedConfig {
  if (!config.application || typeof config.application !== "object") {
    throw new Error("[zapp] config.application is required");
  }
  const name = config.application.name;
  if (typeof name !== "string" || name.trim().length === 0) {
    throw new Error("[zapp] config.application.name must be a non-empty string");
  }
  const normalizedName = name.trim();
  const identifier = config.application.identifier?.trim()
    ?? defaultApplicationIdentifier(normalizedName);
  if (identifier.length === 0) {
    throw new Error("[zapp] config.application.identifier must be a non-empty string");
  }
  const version = config.application.version?.trim() ?? "0.1.0";
  if (version.length === 0) {
    throw new Error("[zapp] config.application.version must be a non-empty string");
  }
  return {
    name: normalizedName,
    identifier,
    version,
    singleInstance: config.application.singleInstance,
    deepLinkSchemes: config.application.deepLinks,
    assetDir: config.frontend?.assets ?? "./dist",
    devPort: config.frontend?.devServer?.port,
    compressAssets: config.frontend?.compressAssets,
    webEngine: config.webview?.engine,
    protocols: config.webview?.protocols,
    webviewPreferences: config.webview?.preferences,
    webviewInject: config.webview?.inject,
    applicationWorkers: config.workers?.application,
    workerModules: config.workers?.modules,
    permissions: config.security?.permissions,
    capabilityProfiles: config.security?.capabilities,
    navigationProfiles: config.security?.navigation,
    fs: config.security?.filesystem,
    native: config.native,
    macos: config.targets?.macOS,
    ios: config.targets?.iOS,
  };
}

export function defaultApplicationIdentifier(name: string): string {
  const slug = name
    .normalize("NFKD")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return `com.zapp.${slug || "app"}`;
}

async function writeResolvedConfigSnapshot(
  root: string,
  context: ZappConfigContext,
  config: ResolvedConfig,
): Promise<void> {
  const directory = path.join(root, ".zapp");
  await mkdir(directory, { recursive: true });
  await writeFile(
    path.join(directory, "config.resolved.json"),
    JSON.stringify({
      version: 2,
      command: context.command,
      mode: context.mode,
      target: context.target,
      config,
    }, null, 2) + "\n",
  );
}

export async function loadConfig(
  root: string,
  context: ZappConfigContext,
): Promise<ResolvedConfig> {
  const absoluteRoot = path.resolve(root);
  const configPath = path.join(absoluteRoot, "zapp.config.ts");
  if (!existsSync(configPath)) {
    const fallback = {
      name: path.basename(absoluteRoot),
      identifier: defaultApplicationIdentifier(path.basename(absoluteRoot)),
      version: "0.1.0",
      assetDir: "./dist",
    };
    await writeResolvedConfigSnapshot(absoluteRoot, context, fallback);
    return fallback;
  }
  try {
    const mod = await import(configPath);
    // Support both `export default defineConfig({...})` and a contextual
    // `export default defineConfig((context) => ({...}))` factory.
    const exported = mod.default as ZappConfigDefinition | undefined;
    if (!exported) {
      throw new Error("[zapp] zapp.config.ts must have a default export");
    }
    const authored = typeof exported === "function"
      ? await exported(context)
      : exported;
    if (!authored || typeof authored !== "object" || Array.isArray(authored)) {
      throw new Error("[zapp] zapp.config.ts must resolve to a configuration object");
    }
    const config = serializableConfigClone(authored);
    validateWebEngine(config.webview?.engine);
    validateWebviewInject(config.webview?.inject);
    validateCapabilityProfiles(
      config.security?.capabilities,
      config.security?.permissions,
    );
    validateNavigationProfiles(config.security?.navigation);
    validateWorkers(config.workers, config.security?.capabilities);
    rejectRemovedEngines(config);
    await substituteZjsOnWindows(config);
    validateNative(config);
    const permErrors = validatePermissions(config.security?.permissions);
    if (permErrors.length > 0) {
      for (const e of permErrors) process.stderr.write(e + "\n");
      throw new Error(permErrors[0]);
    }
    const resolved = normalizeConfig(config);
    await writeResolvedConfigSnapshot(absoluteRoot, context, resolved);
    return resolved;
  } catch (e) {
    if (e instanceof Error && e.message.startsWith("[zapp]")) throw e;
    const detail = e instanceof Error ? e.message : String(e);
    throw new Error(`[zapp] failed to load zapp.config.ts: ${detail}`, { cause: e });
  }
}
