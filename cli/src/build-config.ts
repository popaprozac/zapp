// Generates .zapp/ build artifacts:
// - zapp_build_config.zc — build-time constants
// - zapp_platform.zc — platform .m file compilation directives

import path from "node:path";
import { mkdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import { resolveNative, type ResolvedConfig } from "./config";
import { getPlatformSources, getUserProjectSources, type BuildTarget, detectTarget, isIOSTarget } from "./native";
import { resolveNativeDir, resolveVendorDir } from "./paths";
import { clog, clogError, getCliLevel } from "./log";
import { resolvePermissions } from "./permissions";

// xcrun-resolved iOS SDK paths. Cached for the life of the CLI process
// — calling xcrun is ~80ms, called only once per build now.
const sdkPathCache = new Map<string, string>();
export async function resolveSDKPath(sdk: "iphonesimulator" | "iphoneos"): Promise<string> {
  const cached = sdkPathCache.get(sdk);
  if (cached) return cached;
  const proc = Bun.spawn(["xcrun", "--sdk", sdk, "--show-sdk-path"], {
    stdout: "pipe", stderr: "pipe",
  });
  const out = (await new Response(proc.stdout).text()).trim();
  const exit = await proc.exited;
  if (exit !== 0 || !out) {
    throw new Error(
      `[zapp] couldn't resolve ${sdk} SDK path via xcrun (exit ${exit}). ` +
      `Make sure Xcode + Command Line Tools are installed, then run ` +
      `\`xcodebuild -runFirstLaunch\` and \`sudo xcode-select --install\`.`
    );
  }
  sdkPathCache.set(sdk, out);
  return out;
}

interface BuildConfigOptions {
  root: string;
  config: ResolvedConfig;
  mode: "dev" | "prod";
  devUrl?: string;
  embedAssets?: boolean;
  target?: BuildTarget;
}

export async function generateBuildConfig(opts: BuildConfigOptions): Promise<string> {
  const { root, config, mode, devUrl, embedAssets, target } = opts;
  const zappDir = path.join(root, ".zapp");
  await mkdir(zappDir, { recursive: true });

  const isDev = mode === "dev";
  const initialUrl = isDev && devUrl ? devUrl : "";
  // Forward slashes: this lands inside a C string literal where
  // Windows "\U..." paths are parsed as universal character names and
  // fail to compile. Win32 file APIs accept forward slashes.
  const assetRoot = isDev ? "" : path.resolve(root, config.assetDir).replace(/\\/g, "/");
  const devTools = isDev ? 1 : 0;

  // Runtime policies (acceptFirstMouse, allowNavigation) moved to Zen-C
  // — see WindowOptions.acceptFirstMouse and App.security.allow_navigation.
  // zapp_build_log_level was dead, removed.

  // Filesystem allowlist — emitted as a JSON array literal. The native
  // fs.zc parses this once at startup and prefix-matches every FS call
  // against it. Empty array = FS is fully locked down (every call
  // denied), which is the correct default if the user hasn't opted in.
  const fsAllow = config.fs?.allow ?? [];
  const fsAllowJson = JSON.stringify(fsAllow).replace(/"/g, '\\"');
  const fsPersistGrants = config.fs?.persistDialogGrants ? "true" : "false";

  // Permissions manifest (v1, app-global). Emitted as an escaped JSON
  // object literal; native/permissions/permissions.zc parses it lazily.
  // platform is baked here so the runtime support table needs no extra
  // carrier. active:false (field absent) short-circuits to allow-all.
  const resolvedPerms = resolvePermissions(config.permissions);
  const resolvedTarget = target ?? detectTarget();
  const permsPlatform = isIOSTarget(resolvedTarget)
    ? "ios"
    : resolvedTarget === "windows"
      ? "windows"
      : "macos";
  const permsObj = {
    platform: permsPlatform,
    active: resolvedPerms.active,
    allow: resolvedPerms.allow,
  };
  // Zen-C treats bare `{` / `}` in string literals as f-string
  // interpolation delimiters (same gotcha as the test-infra cycle).
  // Escape them by doubling: `{` → `{{`, `}` → `}}` — the Zen-C
  // runtime emits a single literal brace. Apply AFTER the JSON-escape
  // pass so the `\"` sequences are already in place.
  // fsAllowJson/protocolsJson encode arrays ([…]) so they never emit
  // bare braces — permsObj is the first object-valued JSON in this file,
  // hence the first time brace-escaping is required. Backslash-in-ids is
  // safe because the permission catalog is fixed lowercase ASCII.
  const permissionsJson = JSON.stringify(permsObj)
    .replace(/"/g, '\\"')
    .replace(/\{/g, "{{")
    .replace(/\}/g, "}}");

  // Custom protocols (G19) — declared schemes registered as
  // WKURLSchemeHandlers on every webview. Each scheme name must be
  // a valid URL scheme (lowercase letters / digits / -). Validation
  // is permissive here; WKWebView will reject reserved schemes
  // (http/https/ws/wss/zapp/about/etc.) at the setURLSchemeHandler
  // call with a thrown NSException.
  const protocols = (config.protocols ?? []).filter(s => /^[a-z][a-z0-9.+-]*$/.test(s));
  const protocolsJson = JSON.stringify(protocols).replace(/"/g, '\\"');

  // Deep-link URL schemes (system-wide myapp:// handlers). On macOS
  // these go in Info.plist (CFBundleURLSchemes); on Windows the native
  // platform layer registers them under HKCU\Software\Classes at
  // startup. Same scheme grammar as custom protocols.
  const deepLinkSchemes = (config.deepLinkSchemes ?? []).filter(s => /^[a-z][a-z0-9.+-]*$/.test(s));
  const deepLinkJson = JSON.stringify(deepLinkSchemes).replace(/"/g, '\\"');

  // Webview preferences. Tri-state encoding for booleans so the
  // platform-side code can distinguish "user explicitly set false"
  // from "user didn't touch it" — preserves the WKWebView default
  // when the field is omitted, applies the explicit value when set.
  //   unset → -1   false → 0   true → 1
  // minimumFontSize: -1 when unset, the requested value otherwise.
  const wp = config.webviewPreferences ?? {};
  const tri = (v: boolean | undefined): number =>
    v === undefined ? -1 : (v ? 1 : 0);
  const wpAutoplay  = tri(wp.autoplayWithoutUserGesture);
  const wpBackFwd   = tri(wp.backForwardNavigationGestures);
  const wpTextIA    = tri(wp.textInteractionEnabled);
  const wpMinFont   = wp.minimumFontSize === undefined
    ? -1
    : Math.max(0, Math.round(wp.minimumFontSize));

  const content = `// AUTO-GENERATED by zapp CLI. Do not edit.

fn zapp_build_initial_url() -> string { return "${initialUrl}"; }
fn zapp_build_identifier() -> string { return "${(config.identifier ?? config.name ?? "com.zapp.app").replace(/"/g, "")}"; }
fn zapp_build_asset_root() -> string { return "${assetRoot}"; }
fn zapp_build_use_embedded_assets() -> int { return ${embedAssets ? 1 : 0}; }
fn zapp_build_csp() -> string { return ""; }
fn zapp_build_dev_tools_default() -> int { return ${devTools}; }
fn zapp_build_is_dev() -> int { return ${isDev ? 1 : 0}; }
fn zapp_build_fs_allowlist_json() -> string { return "${fsAllowJson}"; }
fn zapp_build_fs_persist_grants() -> bool { return ${fsPersistGrants}; }
fn zapp_build_custom_protocols_json() -> string { return "${protocolsJson}"; }
fn zapp_build_deep_link_schemes_json() -> string { return "${deepLinkJson}"; }
fn zapp_build_single_instance() -> int { return ${config.singleInstance ? 1 : 0}; }
fn zapp_build_permissions_json() -> string { return "${permissionsJson}"; }
fn zapp_build_webview_autoplay_without_user_gesture() -> int { return ${wpAutoplay}; }
fn zapp_build_webview_back_forward_gestures() -> int { return ${wpBackFwd}; }
fn zapp_build_webview_text_interaction_enabled() -> int { return ${wpTextIA}; }
fn zapp_build_webview_minimum_font_size() -> int { return ${wpMinFont}; }
`;

  const outPath = path.join(zappDir, "zapp_build_config.zc");
  await Bun.write(outPath, content);
  return outPath;
}

// ---------------------------------------------------------------------------
// Nim renderers (Nim migration walking skeleton).
//
// The untouched ObjC `.m` files (webview.m et al.) call the `zapp_build_*`
// config getters and `zapp_webview_bootstrap_script()` as plain C symbols.
// In a Nim-driven build those symbols are emitted as Nim `{.exportc, cdecl.}`
// procs instead of Zen-C `fn`. These pure renderers produce that Nim; the
// existing `.zc` emitters above stay intact until cutover.
//
// Boundary rule (load-bearing): an `{.exportc.}` getter returning a `cstring`
// must be backed by a module-level `let`, NOT a temporary string literal
// returned inline — the `.m` caller may read the pointer past the call, so an
// inline temporary would dangle (use-after-free). Empty `""` cstring literals
// are exempt (they're static storage), so only non-empty config values get a
// module-level `let` backing.
// ---------------------------------------------------------------------------

export interface BuildConfigNimOpts {
  initialUrl: string;
  identifier: string;
  /** App display name (zapp.config.ts `name`) — drives the Nim build's app/menu
   *  name (newApp), matching the zc build's AppConfig.name. */
  name: string;
  assetRoot: string;
  embedAssets: boolean;
  devTools: number;
  isDev: boolean;
  permissionsJson: string;
  fsAllowlistJson: string;
  fsPersistGrants: boolean;
  /** JSON array string of custom protocol schemes (e.g. `'["myapp"]'`).
   *  Mirrors the zc path's `protocolsJson` (build-config.ts:107). Backed by a
   *  module-level `let` per the cstring boundary rule (non-empty pointers must
   *  not dangle). */
  customProtocolsJson: string;
}

/**
 * Render the build-time config getters as Nim `{.exportc, cdecl.}` procs.
 * Emits the full set of `zapp_build_*` symbols the untouched `.m` layer
 * calls (verified against native/platform/darwin/webview.m), plus a
 * `zapp_log_init()` no-op. Non-empty cstrings are backed by module-level
 * `let`s so they never dangle (see the boundary rule above).
 */
export function renderBuildConfigNim(o: BuildConfigNimOpts): string {
  // JSON.stringify produces a valid double-quoted string literal that is
  // also valid as a Nim/C string literal (handles \, ", and control chars).
  const s = (v: string) => JSON.stringify(v);
  const b = (v: boolean) => (v ? "1" : "0");
  return `## AUTO-GENERATED by zapp CLI (Nim). Do not edit.
let zappInitialUrl = ${s(o.initialUrl)}
let zappIdentifier = ${s(o.identifier)}
let zappName = ${s(o.name)}
let zappAssetRoot = ${s(o.assetRoot)}
let zappPermissionsJson = ${s(o.permissionsJson)}
let zappFsAllowlistJson = ${s(o.fsAllowlistJson)}
let zappCustomProtocolsJson = ${s(o.customProtocolsJson)}
proc zapp_build_initial_url(): cstring {.exportc, cdecl.} = zappInitialUrl.cstring
proc zapp_build_identifier(): cstring {.exportc, cdecl.} = zappIdentifier.cstring
proc zapp_build_name(): cstring {.exportc, cdecl.} = zappName.cstring
proc zapp_build_asset_root(): cstring {.exportc, cdecl.} = zappAssetRoot.cstring
proc zapp_build_permissions_json(): cstring {.exportc, cdecl.} = zappPermissionsJson.cstring
proc zapp_build_fs_allowlist_json(): cstring {.exportc, cdecl.} = zappFsAllowlistJson.cstring
proc zapp_build_fs_persist_grants(): bool {.exportc, cdecl.} = ${o.fsPersistGrants ? "true" : "false"}
proc zapp_build_use_embedded_assets(): cint {.exportc, cdecl.} = return ${b(o.embedAssets)}.cint
proc zapp_build_csp(): cstring {.exportc, cdecl.} = "".cstring
proc zapp_build_is_dev(): cint {.exportc, cdecl.} = return ${b(o.isDev)}.cint
proc zapp_build_dev_tools_default(): cint {.exportc, cdecl.} = return ${o.devTools}.cint
proc zapp_build_custom_protocols_json(): cstring {.exportc, cdecl.} = zappCustomProtocolsJson.cstring
proc zapp_build_webview_autoplay_without_user_gesture(): cint {.exportc, cdecl.} = return 0.cint
proc zapp_build_webview_back_forward_gestures(): cint {.exportc, cdecl.} = return 0.cint
proc zapp_build_webview_text_interaction_enabled(): cint {.exportc, cdecl.} = return 1.cint
proc zapp_build_webview_minimum_font_size(): cint {.exportc, cdecl.} = return 0.cint
proc zapp_log_init() {.exportc, cdecl.} = discard
`;
}

/**
 * Render the WebView + worker bootstrap scripts as Nim `{.exportc, cdecl.}`
 * getters. Uses Nim raw string literals (r""" ... """) to avoid escaping the
 * minified bridge JS; the `"""` close-sequence is the one thing a raw
 * literal can't contain, so it's broken up. Each is backed by a module-level
 * `let` per the boundary rule (the `.m`/zjs.c caller may hold the pointer past
 * the call). The worker getter (`zapp_worker_bootstrap_script`) is the twin of
 * the webview one: zjs.c evals it in each worker context after installing the
 * native `__zappBridge`, so the bench's `invokeService` works.
 */
export function renderBootstrapNim(webviewJs: string, workerJs: string): string {
  const esc = (s: string) => s.replace(/"""/g, '"" & "\\"" & "');
  return `## AUTO-GENERATED bootstrap (Nim).
let zappWebviewBootstrap = r"""${esc(webviewJs)}"""
proc zapp_webview_bootstrap_script(): cstring {.exportc, cdecl.} = zappWebviewBootstrap.cstring
let zappWorkerBootstrap = r"""${esc(workerJs)}"""
proc zapp_worker_bootstrap_script(): cstring {.exportc, cdecl, gcsafe.} =
  ## zjs.c calls this from a worker pthread, hence gcsafe. The backing \`let\` is
  ## an immutable module global initialized at startup (before any worker
  ## spawns) and never mutated; \`.cstring\` just hands back its data pointer. The
  ## cast asserts that read is thread-safe (Nim can't prove it for a GC'd global).
  {.cast(gcsafe).}: zappWorkerBootstrap.cstring
`;
}

/**
 * Render the headless-worker spawn calls as a Nim module (zjs-only).
 *
 * Nim analog of `generateHeadlessWorkers` (the `.zc` emitter), but scoped to
 * the worker perf gate: only `engine: "zjs"` entries are emitted — other
 * engines (e.g. bare-jsc) aren't wired in the Nim path and would SIGSEGV. Each
 * zjs entry becomes one `zjs_worker_create` call with the same script URL the
 * `.zc` path uses (`/_workers/_headless_<id>.mjs`, served from dist/_workers)
 * and the same `h-<id>` worker id. `zapp_start_headless_workers()` is called at
 * app boot (app.nim's run()).
 */
export function renderHeadlessNim(headless: Record<string, any> | undefined): string {
  const lines: string[] = [];
  for (const [id, v] of Object.entries(headless ?? {})) {
    const engine = typeof v === "string" ? undefined : v?.engine;
    if (engine !== "zjs") continue; // zjs only for the perf gate
    const engineId = engineNameToId(engine);                  // zjs => 7
    const name = typeof v === "string" ? "" : (v?.name ?? "");
    const escapedName = JSON.stringify(name).slice(1, -1);     // strip surrounding quotes
    const url = `/_workers/_headless_${id}.mjs`;
    // REGISTER (engine + display name) before SPAWNING — the .zc path's
    // zapp_start_headless_worker_full does both. Without the registry entry,
    // Workers.list() is empty AND the router's Workers.send can't resolve the
    // worker to deliver to, so the headless worker is silently unreachable.
    lines.push(
      `  discard zapp_worker_registry_add_full_with_engine_and_name(cstring"h-${id}", cstring"", cstring"${url}", cint(${engineId}), cstring"${escapedName}")`,
    );
    lines.push(
      `  discard zjs_worker_create(cstring"${url}", cstring"", cstring"h-${id}")`,
    );
  }
  return `## AUTO-GENERATED (Nim). zjs headless workers.
proc zjs_worker_create(scriptUrl, ownerId, workerId: cstring): bool {.importc, cdecl.}
proc zapp_worker_registry_add_full_with_engine_and_name(workerId, ownerId: cstring,
    scriptUrl: cstring, engine: cint, name: cstring): cint {.importc, cdecl.}
proc zapp_start_headless_workers*() =
${lines.length ? lines.join("\n") : "  discard"}
`;
}

export interface NimCfgOpts {
  frameworkNimDir: string; // absolute path to the framework's native/nim
  zappDir: string;         // absolute path to the project's .zapp dir
}

/**
 * Render `zapp/nim.cfg` — the editor (nimsuggest / nimlangserver) config that
 * lets `import zapp` resolve in an app's zapp/app.nim. Mirrors the two `--path`
 * values the Nim build passes (native/nim + the generated .zapp/ modules) plus
 * the build's memory/thread flags so the LSP's semantic checks match the real
 * compile. CLI-owned + gitignored: regenerated each build (see buildNativeNim)
 * and at `zapp init`. Both paths are ABSOLUTE so nimsuggest never has to guess
 * which directory a relative cfg path resolves against. Pure (no disk I/O).
 */
export function renderNimCfg(o: NimCfgOpts): string {
  // Forward slashes so the value is benign inside the cfg on Windows too.
  const fw = o.frameworkNimDir.replace(/\\/g, "/");
  const zapp = o.zappDir.replace(/\\/g, "/");
  return `# GENERATED by \`zapp build\`/\`zapp init\` — do not edit.
# Lets nimsuggest/nimlangserver resolve \`import zapp\` (and the framework's
# transitive imports + the generated .zapp/ modules). Regenerated each build.
# Custom flags? Add zapp/app.nim.cfg or zapp/config.nims (the CLI won't touch those).
--path:"${fw}"
--path:"${zapp}"
--mm:orc
--threads:on
`;
}

export interface PlatformNimOpts {
  nativeDir: string; // absolute path to the framework's native/ dir
}

/**
 * Render `.zapp/zapp_platform.nim` — the per-TARGET native link surface for the
 * Nim build path. Replaces the hardcoded darwin-only pragmas that used to live
 * in native/nim/zapp.nim so the Nim build picks the right .m sources, frameworks
 * and libzjs artifact by target (macOS vs iOS).
 *
 * What this module owns (per target):
 *   - the `{.compile(<abs .m>, "-fobjc-arc").}` list (CALL form — the THIRD arg
 *     is per-file clang flags; the TUPLE form `{.compile: (f, x).}` treats the
 *     2nd elem as the OUTPUT OBJECT NAME and would drop ARC + clobber objects,
 *     so it is never used). window.m's weak WKWebView properties REQUIRE ARC.
 *   - the framework `{.passL.}` (Cocoa/Carbon/… on macOS; UIKit/… on iOS).
 *   - the libs `{.passL.}` (-lcompression always; -lz added on iOS).
 *   - the libzjs link `{.passL.}` (libzjs.dylib + rpath on macOS; the static
 *     libzjs_embed.a on iOS, no rpath).
 *
 * What it does NOT own (stays in zapp.nim, target-agnostic):
 *   - the zjs.c `{.compile.}` itself + its `-I vendor/zjs/include` `{.passC.}`
 *     (SDK flags reach it globally via `nim c --passC/--passL`).
 *   - clipboard.m, which clipboard.nim compiles + owns (double-compiling it here
 *     would break the macOS link with duplicate symbols). It is filtered out of
 *     the source list below even though getPlatformSources returns it.
 *
 * Paths are ABSOLUTE (computed from nativeDir + the vendor dir). The generated
 * module lives in the project's .zapp/ dir, so a relative `../platform/...`
 * `{.compile.}` would resolve against .zapp/ (= <project>/platform/...) instead
 * of the framework's native/ — absolute paths sidestep that quirk entirely.
 * Pure (no disk I/O); buildNativeNim writes the returned source to disk.
 */
export function renderPlatformNim(target: BuildTarget, o: PlatformNimOpts): string {
  // Forward slashes so the emitted Nim string literals are benign everywhere.
  const slash = (s: string) => s.replace(/\\/g, "/");
  const ios = isIOSTarget(target);

  // .m source list for the target (darwin vs ios). getPlatformSources returns
  // absolute paths filtered to existing files. clipboard.m is dropped — it is
  // compiled by clipboard.nim, not this module (see the doc comment).
  const sources = getPlatformSources(o.nativeDir, target)
    .filter((f) => path.basename(f) !== "clipboard.m");
  const compileLines = sources
    .map((f) => `{.compile("${slash(f)}", "-fobjc-arc").}`)
    .join("\n");

  // libzjs lives at <native>/../vendor/zjs/build (vendor is a sibling of
  // native/) — the same two-levels-up location the old zapp.nim resolved via
  // currentSourcePath().parentDir & "/../../vendor/zjs/build". Resolve it
  // absolutely from nativeDir so the .zapp/ module doesn't depend on its own
  // location.
  const zjsBuildDir = slash(path.join(o.nativeDir, "..", "vendor", "zjs", "build"));

  if (ios) {
    // iOS: UIKit replaces Cocoa; no Carbon (RegisterEventHotKey is macOS-only,
    // ios/shortcuts.m is a no-op stub). Mirrors build-config.ts's iOS framework
    // set (the .zc path) so both build paths agree.
    const frameworks = [
      "UIKit",
      "Foundation",
      "WebKit",
      "JavaScriptCore",
      "UserNotifications",
      "UniformTypeIdentifiers",
      "Security",
    ].map((f) => `-framework ${f}`).join(" ");
    // simulator-arm64 static slice; -device targets get their own slice in a
    // later task. -lz (zlib) is required on iOS (libz.tbd in the SDK) — the
    // macOS link resolves deflate/inflate transitively from libSystem but the
    // iOS link does not. No rpath: the .a is linked statically.
    const embed = `${zjsBuildDir}/ios/simulator-arm64/libzjs_embed.a`;
    return `## AUTO-GENERATED (Nim) — per-target native link surface. Do not edit.
## Target: ${target}. Regenerated each build by buildNativeNim (cli/src/native.ts).
## Owns the .m compile list + frameworks + libzjs link for this target; the
## zjs.c compile + its -Ivendor/zjs/include passC stay in zapp.nim (SDK flags
## reach them globally). The clipboard ObjC source is compiled by clipboard.nim, not here.
${compileLines}
{.passL: "${frameworks}".}
{.passL: "-lcompression".}  # zjs.c embedded-asset decode (compression_decode_buffer)
{.passL: "-lz".}            # zjs host_zlib_codec deflate/inflate (libz.tbd, iOS SDK)
{.passL: "${embed}".}
`;
  }

  // macOS: reproduce today's zapp.nim pragmas verbatim — same framework set
  // (line 12), -lcompression, libzjs.dylib absolute path + an -rpath so the
  // raw bin/ binary finds the dylib at run time.
  const frameworks =
    "-framework Cocoa -framework WebKit -framework CoreFoundation -framework JavaScriptCore " +
    "-framework Security -framework IOKit -framework ServiceManagement -framework UserNotifications " +
    "-framework Carbon -framework Foundation";
  const dylib = `${zjsBuildDir}/libzjs.dylib`;
  return `## AUTO-GENERATED (Nim) — per-target native link surface. Do not edit.
## Target: ${target}. Regenerated each build by buildNativeNim (cli/src/native.ts).
## Owns the .m compile list + frameworks + libzjs link for this target; the
## zjs.c compile + its -Ivendor/zjs/include passC stay in zapp.nim (SDK flags
## reach them globally). The clipboard ObjC source is compiled by clipboard.nim, not here.
${compileLines}
{.passL: "${frameworks}".}
{.passL: "-lcompression".}  # zjs.c:1208 compression_decode_buffer (embedded-asset decode)
{.passL: "${dylib}".}
{.passL: "-Wl,-rpath,${zjsBuildDir}".}
`;
}

// Generate .zapp/zapp_headless_workers.zc — the function native/app/app.zc
// declares as `extern fn zapp_start_headless_workers()`. Body contains one
// call per entry in zappConfig.headless; empty body when no headless workers
// are configured.
// String → ZAPP_ENGINE_* numeric ID matching native/worker/registry.zc.
// Mirror of the constants there so the generated headless-worker
// invocations pass the right integer per engine.
// -1 means "let the resolver pick the first available engine."
function engineNameToId(name: string | undefined): number {
  switch (name) {
    case "bare-jsc":     return 2;
    case "bare-v8":      return 3;
    case "bare-quickjs": return 4;
    case "bare-mqjs":    return 5;
    case "bare-hermes":  return 6;
    case "zjs":          return 7;
    default:             return -1;
  }
}

export async function generateHeadlessWorkers(opts: {
  root: string;
  headless?: Record<string, string | {
    script: string;
    name?: string;
    restart?: { maxRetries?: number; withinMs?: number } | false;
    engine?: "bare-jsc" | "bare-v8" | "bare-quickjs" | "bare-mqjs" | "bare-hermes" | "zjs";
    bytecode?: boolean;  // type-narrowed at the user-facing HeadlessWorkerConfig boundary
  }>;
}): Promise<string> {
  const { root, headless } = opts;
  const zappDir = path.join(root, ".zapp");
  await mkdir(zappDir, { recursive: true });

  const entries = Object.entries(headless ?? {});
  const calls = entries
    .map(([id, value]) => {
      // Bare string → no engine, no restart policy, no bytecode.
      if (typeof value === "string") {
        const url = `/_workers/_headless_${id}.mjs`;
        return `    zapp_start_headless_worker("h-${id}", "${url}");`;
      }
      // Object form. Pull engine + restart + bytecode.
      const engineId = engineNameToId(value.engine);
      const restart = value.restart;
      const max = restart ? (restart.maxRetries ?? 3) : 0;
      const within = restart ? (restart.withinMs ?? 60_000) : 0;
      // Optional display name — escaped for embedding as a C string
      // literal in the generated Zen-C source. JSON.stringify produces a
      // fully-escaped double-quoted string (handles \, ", \n, \r, \t and
      // other control chars); .slice(1, -1) strips the surrounding quotes
      // since the codegen template below already wraps it in "...".
      // Same idiom as fsAllowJson / protocolsJson above.
      const name = value.name ?? "";
      const escapedName = JSON.stringify(name).slice(1, -1);
      // bytecode: true is only meaningful for zjs. The CLI build step
      // produces a sibling .zbc file via `zjs compile`; the engine
      // detects the extension and dispatches to zjs_eval_bytecode.
      if (value.bytecode && value.engine !== "zjs") {
        throw new Error(
          `[zapp] headless worker "${id}": \`bytecode: true\` is only supported for ` +
          `\`engine: "zjs"\` (got \`engine: "${value.engine}"\`).`
        );
      }
      const ext = value.bytecode ? "zbc" : "mjs";
      const url = `/_workers/_headless_${id}.${ext}`;
      return `    zapp_start_headless_worker_full("h-${id}", "${url}", ${engineId}, ${max}, ${within}, "${escapedName}");`;
    })
    .join("\n");

  const body = calls || `    // No headless workers configured.`;

  const content = `// AUTO-GENERATED by zapp CLI. Do not edit.
// Implementation for native/app/app.zc's extern fn zapp_start_headless_workers().

fn zapp_start_headless_workers() -> void {
${body}
}
`;

  const outPath = path.join(zappDir, "zapp_headless_workers.zc");
  await Bun.write(outPath, content);
  return outPath;
}

/**
 * For iOS targets: generate a substitute build.zc that strips the
 * user's `//> macos: ...` directives (zc applies them based on host
 * platform, not build target — so without this they pull in
 * Cocoa.framework for iOS builds and link fails with "framework Cocoa
 * not found"). Imports / defines / pragmas the user wrote outside the
 * `macos:` prefix carry through unchanged.
 *
 * Also injects the iOS-needed defines (apple, ZAPP_WORKER_ENGINE_*)
 * since the user's `macos:` versions of those just got stripped.
 *
 * Engine selection is taken from BOTH the user's build.zc declarations
 * AND `zapp.config.ts` headless entries' `engine:` field. The latter
 * is the modern path — without it, a config-only engine (e.g.
 * `engine: "zjs"`) would silently fall back to the bare-jsc default
 * because the iOS overlay used to only look at build.zc text.
 */
export async function generateIOSBuildFile(
  root: string,
  originalBuildFile: string,
  config?: ResolvedConfig,
): Promise<string> {
  let content = "";
  try {
    content = await Bun.file(originalBuildFile).text();
  } catch { content = ""; }

  // Strip uncommented `//> macos: ...` lines. We KEEP `// //> macos: ...`
  // (still commented) lines so the generated file is human-readable
  // when debugging.
  const filtered = content
    .split("\n")
    .filter(line => !/^\/\/>\s*macos:/.test(line.trim()))
    .join("\n");

  // Worker engine selection on iOS — union of:
  //   1. build.zc `//> define: ZAPP_WORKER_ENGINE_*` declarations (the
  //      escape hatch path).
  //   2. zapp.config.ts headless entries' `engine:` field (the
  //      modern path — what hello-world and most apps use).
  // Falls back to bare-jsc (zero binary cost via the JSC system
  // framework; JIT-less on iOS by Apple policy) when neither source
  // names an engine.
  //
  // bare-v8 is intentionally NOT exposed for iOS — V8 needs JIT pages
  // (`MAP_JIT`) which Apple gates behind entitlements not granted to
  // App Store apps. If the user named bare-v8 in either source, we
  // warn and fall back to bare-jsc.
  const userPickedBareJsc   = /^\/\/>.*define:.*ZAPP_WORKER_ENGINE_BARE_JSC/m.test(content);
  const userPickedBareQuick = /^\/\/>.*define:.*ZAPP_WORKER_ENGINE_BARE_QUICKJS/m.test(content);
  const userPickedBareV8    = /^\/\/>.*define:.*ZAPP_WORKER_ENGINE_BARE_V8/m.test(content);
  const userPickedBareHermes = /^\/\/>.*define:.*ZAPP_WORKER_ENGINE_BARE_HERMES/m.test(content);
  const userPickedZjs       = /^\/\/>.*define:.*ZAPP_WORKER_ENGINE_ZJS\b/m.test(content);

  // Walk zapp.config.ts headless entries to pick up engines named
  // there but not declared in build.zc. Same engine set the
  // engine-overlay generator looks at — they need to stay in sync
  // so the iOS build sees the same engine list as the macOS build.
  const configEngines = new Set<string>();
  for (const value of Object.values(config?.headless ?? {})) {
    if (typeof value === "object" && value && "engine" in value && value.engine) {
      configEngines.add(value.engine);
    }
  }
  const configHasBareJsc    = configEngines.has("bare-jsc");
  const configHasBareQuick  = configEngines.has("bare-quickjs");
  const configHasBareV8     = configEngines.has("bare-v8");
  const configHasBareHermes = configEngines.has("bare-hermes");
  const configHasZjs        = configEngines.has("zjs");

  // V8 on iOS is a dead end: full V8 needs JIT pages (`mmap(PROT_EXEC)`)
  // which Apple gates behind a JIT entitlement not granted to App
  // Store apps. The fallback (jitless V8) would run as a ~30 MB
  // interpreter — perf is on par with bare-quickjs at ~1.5 MB.
  // Surface this explicitly so users don't think they're getting V8
  // speed on their iOS build.
  if (userPickedBareV8 || configHasBareV8) {
    clog(0,
      "note: bare-v8 isn't useful on iOS (no JIT entitlement for App Store apps).\n" +
      "       Falling back to bare-jsc for this build.\n" +
      "       Use 'bare-quickjs' explicitly if you want cross-platform interpreter parity."
    );
  }

  const engineDefines: string[] = [];
  if (userPickedBareJsc    || configHasBareJsc)    engineDefines.push("ZAPP_WORKER_ENGINE_BARE_JSC");
  if (userPickedBareQuick  || configHasBareQuick)  engineDefines.push("ZAPP_WORKER_ENGINE_BARE_QUICKJS");
  if (userPickedBareHermes || configHasBareHermes) engineDefines.push("ZAPP_WORKER_ENGINE_BARE_HERMES");
  if (userPickedZjs        || configHasZjs)        engineDefines.push("ZAPP_WORKER_ENGINE_ZJS");
  if (engineDefines.length === 0) engineDefines.push("ZAPP_WORKER_ENGINE_BARE_JSC");

  const iosOverlay = `
// AUTO-GENERATED for iOS builds. Strips macos:-prefixed directives
// from the user's build.zc (which zc applies based on host platform
// rather than build target) and re-emits the iOS-appropriate set.
//> define: apple
${engineDefines.map(d => `//> define: ${d}`).join("\n")}
`;

  // Write into the hidden `.zapp/` dir alongside the other generated
  // artifacts (zapp_platform.zc, engine overlay, worker bundles) so the
  // visible `zapp/` dir only ever shows the user's own files. The
  // generated file re-emits the user's build.zc body (which uses bare
  // module names like `import "app.zc"` resolved against zc's include
  // path), so its location is independent of the original.
  const zappDir = path.join(root, ".zapp");
  await mkdir(zappDir, { recursive: true });
  const iosBuildFile = path.join(zappDir, "_zapp_build_ios.zc");
  await Bun.write(iosBuildFile, iosOverlay + filtered);
  return iosBuildFile;
}

// Generate `.zapp/zapp_engine_overlay.zc` — a build-time overlay that adds
// `//> define: ZAPP_WORKER_ENGINE_*` directives for engines a user reached
// for in `zapp.config.ts` headless map but didn't manually opt into via
// `zapp/build.zc`. Lets users say `engine: "bare-quickjs"` in config and
// have the engine "just appear" in the build — the CLI builds engines you
// reference; you don't have to learn build directives to use a worker.
//
// Returns the overlay file path, or null if no overlay is needed (every
// engine the project references is already declared in build.zc).
// Idempotent flag for the "engine declared in build.zc is deprecated"
// nudge — module-scoped so dev mode's repeated rebuilds don't spam
// the same warning on every save.
let _engineBuildZcWarned = false;

export async function generateEngineOverlay(opts: {
  root: string;
  target: BuildTarget;
  config: ResolvedConfig;
}): Promise<string | null> {
  const { root, target, config } = opts;

  // 1. Read what's already in build.zc.
  const buildFile = path.join(root, "zapp", "build.zc");
  let buildContent = "";
  try { buildContent = await Bun.file(buildFile).text(); } catch {}

  const declared = (m: string) => new RegExp(`^//>.*define:.*${m}\\b`, "m").test(buildContent);
  const have = {
    "bare-jsc":    declared("ZAPP_WORKER_ENGINE_BARE_JSC"),
    "bare-v8":     declared("ZAPP_WORKER_ENGINE_BARE_V8"),
    "bare-quickjs":declared("ZAPP_WORKER_ENGINE_BARE_QUICKJS"),
    "bare-mqjs":   declared("ZAPP_WORKER_ENGINE_BARE_MQJS"),
    "bare-hermes": declared("ZAPP_WORKER_ENGINE_BARE_HERMES"),
    zjs:           declared("ZAPP_WORKER_ENGINE_ZJS"),
  };

  // Deprecation nudge — engine selection now lives in zapp.config.ts
  // (the CLI synthesizes the matching `ZAPP_WORKER_ENGINE_*` define).
  // The build.zc `//>` form keeps working as an escape hatch for now,
  // but spelling the engine in two places lets the sources of truth
  // drift silently. Warn once per offending define so existing apps
  // know what to migrate without spamming on every rebuild.
  const declaredInBuildZc = (Object.entries(have) as [string, boolean][])
    .filter(([, v]) => v)
    .map(([k]) => k);
  if (declaredInBuildZc.length > 0 && !_engineBuildZcWarned) {
    _engineBuildZcWarned = true;
    clogError(
      `zapp/build.zc declares engine define(s) for ${declaredInBuildZc.join(", ")} ` +
      `via \`//> define: ZAPP_WORKER_ENGINE_*\`. Engine selection has moved to ` +
      `zapp.config.ts — set \`engine: "..."\` on the relevant headless entry (and ` +
      `the CLI emits the matching define). The build.zc form still works but is ` +
      `deprecated; expect removal in a future alpha.`
    );
  }

  // 2. Walk headless config — pick up any `engine:` field.
  const wanted = new Set<string>();
  for (const value of Object.values(config.headless ?? {})) {
    if (typeof value === "object" && value && "engine" in value && value.engine) {
      wanted.add(value.engine);
    }
  }

  // 3. If the project references workers but no engine is named anywhere
  //    (neither a build.zc `//>` directive nor a per-worker `engine:`
  //    field in `zapp.config.ts`), pick a sensible per-platform default.
  //    The matrix lives in cli/src/native.ts:defaultBareEngine — bare-jsc
  //    on Apple (free, JIT with entitlement), bare-v8 elsewhere.
  //
  //    Checking `wanted.size === 0` here (not just `!anyDeclared`) is
  //    load-bearing once apps stop declaring engines in build.zc and
  //    rely purely on `zapp.config.ts`. Otherwise a config-pinned worker
  //    (e.g. `engine: "zjs"`) would also pull in the default bare-* —
  //    duplicate engine in the binary, wrong worker engine picked at
  //    runtime if the resolver downgrade chain crosses them.
  const anyDeclared = Object.values(have).some(Boolean);
  const hasWorkers = (config.headless && Object.keys(config.headless).length > 0)
    || wanted.size > 0;
  if (!anyDeclared && wanted.size === 0 && hasWorkers) {
    // Defer the import — keep this file's deps narrow.
    const { defaultBareEngine } = await import("./native");
    const engine = defaultBareEngine(target);
    wanted.add("bare-" + engine);
  }

  // 4. Compute the missing set (wanted - already-declared).
  const missing: string[] = [];
  for (const w of wanted) {
    if (!(w in have)) continue; // unknown engine string — config validation should've caught it
    if (!have[w as keyof typeof have]) {
      const def = w === "bare-jsc"      ? "ZAPP_WORKER_ENGINE_BARE_JSC"
                : w === "bare-v8"       ? "ZAPP_WORKER_ENGINE_BARE_V8"
                : w === "bare-quickjs"  ? "ZAPP_WORKER_ENGINE_BARE_QUICKJS"
                : w === "bare-mqjs"     ? "ZAPP_WORKER_ENGINE_BARE_MQJS"
                : w === "bare-hermes"   ? "ZAPP_WORKER_ENGINE_BARE_HERMES"
                : w === "zjs"           ? "ZAPP_WORKER_ENGINE_ZJS"
                : null;
      if (def) missing.push(def);
    }
  }

  if (missing.length === 0) return null;

  // Apple-target engines are macOS- AND iOS-relevant; we leave the
  // platform prefix off so zc applies to whichever host. (`generateIOSBuildFile`
  // strips macos: directives, so a non-prefixed define carries through to iOS.)
  const body = `// AUTO-GENERATED engine overlay. Adds defines for engines reached
// for in zapp.config.ts but not declared in zapp/build.zc.
${missing.map(d => `//> define: ${d}`).join("\n")}
`;

  const zappDir = path.join(root, ".zapp");
  await mkdir(zappDir, { recursive: true });
  const overlayPath = path.join(zappDir, "zapp_engine_overlay.zc");
  await Bun.write(overlayPath, body);
  return overlayPath;
}

// Generate .zapp/zapp_platform.zc with .m file cflags. The optional
// `engineOverlayFile` lets the platform scan also see engine defines
// the CLI auto-generated from zapp.config.ts (parallels how
// generateEngineOverlay produces them).
export async function generatePlatformConfig(
  root: string,
  target: BuildTarget = detectTarget(),
  buildFile?: string,
  engineOverlayFile?: string,
  config?: ResolvedConfig,
): Promise<string> {
  const zappDir = path.join(root, ".zapp");
  await mkdir(zappDir, { recursive: true });

  const nativeDir = resolveNativeDir();
  const sources = getPlatformSources(nativeDir, target);

  // Append user-authored ObjC/C sources from the project's zapp/ tree.
  // This lets apps ship a service implementation in a .m (or .c on
  // Windows) file without modifying the framework. Scans recursively.
  const userSources = await getUserProjectSources(root, target);
  if (userSources.length > 0) {
    sources.push(...userSources);
    const relPaths = userSources.map(s => path.relative(root, s));
    clog(1, `user sources: ${relPaths.join(", ")}`);
  }

  // Check enabled worker engines from user's build.zc directives AND
  // from the CLI-generated engine overlay (when present). Concatenating
  // the two sources lets users name engines in zapp.config.ts without
  // also having to add `//> define:` directives by hand.
  const bareEngines: ("v8" | "jsc" | "quickjs" | "mqjs" | "hermes")[] = [];
  const userBuild = buildFile ?? path.join(root, "zapp", "build.zc");
  let buildContent = "";
  try { buildContent += await Bun.file(userBuild).text() + "\n"; } catch {}
  if (engineOverlayFile) {
    try { buildContent += await Bun.file(engineOverlayFile).text(); } catch {}
  }
  const hasZjs = /^\/\/>.*define:.*ZAPP_WORKER_ENGINE_ZJS\b/m.test(buildContent);
  if (/^\/\/>.*define:.*ZAPP_WORKER_ENGINE_BARE_V8/m.test(buildContent)) bareEngines.push("v8");
  if (/^\/\/>.*define:.*ZAPP_WORKER_ENGINE_BARE_JSC/m.test(buildContent)) bareEngines.push("jsc");
  if (/^\/\/>.*define:.*ZAPP_WORKER_ENGINE_BARE_QUICKJS/m.test(buildContent)) bareEngines.push("quickjs");
  if (/^\/\/>.*define:.*ZAPP_WORKER_ENGINE_BARE_MQJS/m.test(buildContent)) bareEngines.push("mqjs");
  if (/^\/\/>.*define:.*ZAPP_WORKER_ENGINE_BARE_HERMES/m.test(buildContent)) bareEngines.push("hermes");
  if (bareEngines.length > 0) {
    // Single bare.c source handles all enabled engines via #ifdef on
    // the ZAPP_WORKER_ENGINE_BARE_* defines. The libs differ per
    // engine but the dispatcher code is the same.
    const bareC = path.join(nativeDir, "worker", "engines", "bare.c");
    if (existsSync(bareC)) sources.push(bareC);
  }
  if (hasZjs) {
    const zjsC = path.join(nativeDir, "worker", "engines", "zjs.c");
    if (existsSync(zjsC)) sources.push(zjsC);
  }

  let content = "// AUTO-GENERATED by zapp CLI. Do not edit.\n// Platform-specific compilation sources.\n\n";

  // Emit paths relative to the project root when that's shorter than the
  // absolute form. zc has a fixed-size buffer for accumulated build
  // directives; long absolute paths (especially for projects installing
  // the CLI under node_modules/@zappdev/cli/) can overflow it, silently
  // dropping trailing directives. Since zc invokes clang with cwd = project
  // root, relative paths resolve identically. Picking the shorter form
  // per-path keeps vendor paths in ~/.zapp/vendor from blowing up as
  // "../../../../..".
  const shortPath = (abs: string): string => {
    const rel = path.relative(root, abs);
    return rel.length < abs.length ? rel : abs;
  };

  // Native extras from zapp.config.ts — the grouped `native:` block AND
  // the deprecated flat fields (`extraFrameworks` / `extraLinkFlags` /
  // `nativeSources`), merged + de-duped per-target by `resolveNative`,
  // which collapses both iOS subtargets to the "ios" bucket internally.
  const {
    frameworks: userExtraFrameworks,
    linkFlags: userExtraLinkFlags,
    sources: userNativeSources,
  } = resolveNative(config ?? ({} as ResolvedConfig), target);
  // Resolve user source paths relative to project root.
  const resolvedUserSources = userNativeSources.map(s => path.resolve(root, s));

  if (target === "macos" && sources.length > 0) {
    // ObjC ARC for the framework's own .m files. Bundle `-fobjc-arc`
    // onto the same `//> macos: cflags:` line as the sources so zc
    // applies it directly to those compile units. Splitting it onto
    // its own directive intermittently lost the flag on bench-shaped
    // builds (window.m's `__weak NSWindow*` then failed with
    // "cannot create __weak reference in file using manual reference
    // counting").
    const macSources = [...sources, ...resolvedUserSources];
    content += `//> macos: cflags: -fobjc-arc ${macSources.map(shortPath).join(" ")}\n`;
    // Framework-internal system framework set — the boilerplate that
    // every Zapp macOS app needs, regardless of what the app itself
    // links. Generating these here means the user's hand-written
    // `zapp/build.zc` stays free of platform plumbing it shouldn't
    // know about. Apps that need additional frameworks declare them
    // via `extraFrameworks` in zapp.config.ts.
    content += `//> macos: framework: Cocoa\n`;
    content += `//> macos: framework: WebKit\n`;
    content += `//> macos: framework: CoreFoundation\n`;
    content += `//> macos: framework: JavaScriptCore\n`;
    content += `//> macos: framework: Security\n`;
    content += `//> macos: framework: UserNotifications\n`;
    // Carbon — RegisterEventHotKey + friends for shortcuts.m.
    content += `//> macos: framework: Carbon\n`;
    // ServiceManagement — SMAppService.mainApp for App.setLoginItem (macOS 13+).
    content += `//> macos: framework: ServiceManagement\n`;
    // IOKit — IOPowerSources for App.getPowerState() AC/battery monitoring.
    content += `//> macos: framework: IOKit\n`;
    // libcompression — embedded-asset brotli decode path.
    content += `//> macos: link: -lcompression\n`;
    // libz (zlib) — zjs's host_zlib_codec. Resolved transitively from
    // libSystem on macOS today, but declared explicitly so the dependency
    // is honest and can't silently regress (the iOS link needs it outright).
    content += `//> macos: link: -lz\n`;
    // App-declared extras from zapp.config.ts.
    for (const fw of userExtraFrameworks) content += `//> macos: framework: ${fw}\n`;
    if (userExtraLinkFlags.length > 0) {
      content += `//> macos: link: ${userExtraLinkFlags.join(" ")}\n`;
    }
  }
  if (isIOSTarget(target) && sources.length > 0) {
    // Pick the right SDK + arch for the target. Simulator on Apple
    // Silicon Macs is arm64 (uses iphonesimulator SDK with simulator
    // version-min); device is arm64 too but uses iphoneos SDK and the
    // production version-min. Both flow through clang via cflags
    // pass-through; zc itself doesn't need iOS-specific knowledge.
    const sdk = target === "ios-simulator" ? "iphonesimulator" : "iphoneos";
    const versionMinFlag = target === "ios-simulator"
      ? "-mios-simulator-version-min=15.0"
      : "-miphoneos-version-min=15.0";
    // resolveSdkPath caches the xcrun result; called once per build.
    const sdkPath = await resolveSDKPath(sdk);
    const iosCflags = [
      "-arch", "arm64",
      "-isysroot", sdkPath,
      versionMinFlag,
      // ObjC ARC is on for our .m sources; matches the macOS path.
      "-fobjc-arc",
    ].join(" ");
    const iosSources = [...sources, ...resolvedUserSources];
    content += `//> cflags: ${iosCflags} ${iosSources.map(shortPath).join(" ")}\n`;
    content += `//> link: -arch arm64 -isysroot ${sdkPath} ${versionMinFlag}\n`;
    // iOS frameworks: UIKit replaces Cocoa; WebKit + JavaScriptCore
    // are the same as macOS. Foundation is implicit but listing it for
    // clarity. No Carbon — RegisterEventHotKey / shortcuts.m are
    // macOS-only and the iOS shortcuts.m is a no-op stub.
    content += `//> framework: UIKit\n`;
    content += `//> framework: Foundation\n`;
    content += `//> framework: WebKit\n`;
    content += `//> framework: JavaScriptCore\n`;
    // UniformTypeIdentifiers — used by ios/dialog.m for UIDocumentPicker
    // file-type filtering (UTType). iOS 14+ system framework.
    content += `//> framework: UniformTypeIdentifiers\n`;
    // UserNotifications — used by ios/notification.m. Same framework as
    // macOS (UNUserNotificationCenter API is cross-Apple-platform).
    content += `//> framework: UserNotifications\n`;
    // libcompression — used by jsc.m for embedded-asset brotli decode.
    // Available on iOS as a system library; just needs the link flag.
    content += `//> link: -lcompression\n`;
    // libz (zlib) — zjs's host_zlib_codec calls deflate/inflate. macOS
    // resolves these transitively from libSystem, but the iOS link line
    // does not, so it must be requested explicitly (libz.tbd ships in the
    // iOS SDK). Without it: "Undefined symbols: _deflate, _deflateInit2_".
    content += `//> link: -lz\n`;
    // App-declared extras from zapp.config.ts.
    for (const fw of userExtraFrameworks) content += `//> framework: ${fw}\n`;
    if (userExtraLinkFlags.length > 0) {
      content += `//> link: ${userExtraLinkFlags.join(" ")}\n`;
    }
  }
  // Worker-engine link plumbing — accumulate all -L search paths and
  // -l<name> flags into a single `//> link:` directive emitted at the end.
  const allLinkSearchDirs: string[] = [];
  const allLinkLibs: string[] = [];
  // Windows link flags destined for the GCC @file response file —
  // written once at the end (bare flush + zjs block both contribute).
  const windowsRspFlags: string[] = [];

  // Bare runtime — link each enabled engine. Use zc's dedicated
  // `//> include:` (for -I) and `//> lib:` (for -L) directives rather
  // than packing -I/-L into `cflags:` / `link:`. Per the docs (Zen-C
  // tour 12.5 Build Directives), these have purpose-specific
  // accumulation behavior; bundling search paths into a generic
  // link: directive doesn't reliably extend the previous one.
  if (bareEngines.length > 0) {
    const { resolveBareDir } = await import("./paths");
    const { bareBuildDirName } = await import("./native");
    const bareDir = await resolveBareDir();
    const bareInclude = path.join(bareDir, "include");
    if (existsSync(path.join(bareInclude, "bare.h"))) {
      content += `//> cflags: -I${shortPath(bareInclude)}\n`;

      for (const engine of bareEngines) {
        const buildSubdir = bareBuildDirName(target, engine);
        const bareBuild = path.join(bareDir, buildSubdir);
        // js.h lives in the libjs abstraction layer (always pulled in
        // by Bare regardless of which engine backs it).
        const libjsInclude = path.join(bareBuild, "_deps",
            "github+holepunchto+libjs-src", "include");
        if (existsSync(libjsInclude)) {
          content += `//> cflags: -I${shortPath(libjsInclude)}\n`;
        }
        const engineSrcMap: Record<string, string> = {
          v8: "github+holepunchto+libjs-src",
          jsc: "github+holepunchto+libjsc-src",
          quickjs: "github+holepunchto+libqjs-src",
          mqjs: "github+holepunchto+libmqjs-src",
          hermes: "github+popaprozac+libhermes-src",
        };
        const engineSrc = path.join(bareBuild, "_deps", engineSrcMap[engine], "include");
        if (existsSync(engineSrc) && engine !== "v8") {
          content += `//> cflags: -I${shortPath(engineSrc)}\n`;
        }
        const libuvInclude = path.join(bareBuild, "_deps",
            "github+libuv+libuv-src", "include");
        if (existsSync(libuvInclude)) {
          content += `//> cflags: -I${shortPath(libuvInclude)}\n`;
        }
        const libutfInclude = path.join(bareBuild, "_deps",
            "github+holepunchto+libutf-src", "include");
        if (existsSync(libutfInclude)) {
          content += `//> cflags: -I${shortPath(libutfInclude)}\n`;
        }
        const libBare = path.join(bareBuild, "libbare.a");
        if (existsSync(libBare)) {
          // V8 uses BARE_PREBUILDS=ON which places libjs.a (and libv8.a,
          // libc++.a) under `darwin-arm64/` rather than the usual
          // `_deps/<repo>-build` tree the other engines use.
          let engineBuild: string;
          if (engine === "v8") {
            engineBuild = path.join(bareBuild, "darwin-arm64");
          } else {
            const engineBuildMap: Record<string, string> = {
              jsc: "github+holepunchto+libjsc-build",
              quickjs: "github+holepunchto+libqjs-build",
              mqjs: "github+holepunchto+libmqjs-build",
              hermes: "github+popaprozac+libhermes-build",
            };
            engineBuild = path.join(bareBuild, "_deps", engineBuildMap[engine]);
          }
          const libuvBuild = path.join(bareBuild, "_deps", "github+libuv+libuv-build");
          const libutfBuild = path.join(bareBuild, "_deps", "github+holepunchto+libutf-build");
          // We pass static .a files as positional arguments rather
          // than `-L<dir> -l<name>` for libuv specifically. Reason:
          // homebrew installs `libuv.dylib` in `/opt/homebrew/lib/`,
          // which is on most devs' default link search path
          // (LIBRARY_PATH or implicit). With bare compiled in, `-luv`
          // falls through to homebrew's dylib — produces a binary with
          // an unsatisfiable @rpath/libuv.1.dylib reference at launch.
          // Passing the .a file directly forces static linking and
          // makes the build platform-installed-dylib-proof.
          //
          // For libutf and the engine-specific binding (libjs.a) we
          // keep the -L+-l form because there's no system collision —
          // those libs only exist in our build dir.
          const libuvA = path.join(libuvBuild, "libuv.a");
          // For V8 we skip adding engineBuild to -L; otherwise `-lc++`
          // resolves to V8's bundled libc++.a (`__Cr` namespace)
          // before falling through to Apple's stock libc++ (`__1`
          // namespace), and BoringSSL needs the latter. We pass
          // libv8.a + libc++.a positionally below instead.
          allLinkSearchDirs.push(shortPath(bareBuild));
          if (engine !== "v8") allLinkSearchDirs.push(shortPath(engineBuild));
          allLinkSearchDirs.push(shortPath(libutfBuild));
          allLinkLibs.push("-lbare");
          if (engine !== "v8") allLinkLibs.push("-ljs");
          allLinkLibs.push("-lutf");
          if (engine === "v8") {
            const libjsA = path.join(engineBuild, "libjs.a");
            if (existsSync(libjsA)) {
              const flag = shortPath(libjsA);
              if (!allLinkLibs.includes(flag)) allLinkLibs.push(flag);
            }
          }
          if (existsSync(libuvA)) {
            // Avoid duplicates if multiple bare engines compile in.
            const libuvFlag = shortPath(libuvA);
            if (!allLinkLibs.includes(libuvFlag)) allLinkLibs.push(libuvFlag);
          }
          // V8 needs the engine itself + libc++ as separate libs (the
          // libjsc binding is header-only against the system framework
          // so doesn't need this; QJS and mQJS link the engine via
          // their respective libjs binding).
          //
          // CRUCIAL detail when BoringSSL is also on the link line:
          // V8's prebuilt libc++.a uses Holepunch's custom inline
          // namespace `__Cr` (the build uses LIBCXX_ABI_NAMESPACE to
          // avoid clashing with the system libc++), while Apple's
          // stock libc++ uses `__1`. They expose completely different
          // mangled symbols. BoringSSL was compiled against stock
          // Apple libc++, so it needs `__1` versions of std::__sort
          // etc., which V8's bundled libc++.a CANNOT provide.
          //
          // We solve this by:
          //   1. Passing V8's libc++.a as an absolute positional
          //      argument — gives `__Cr` symbols for V8 itself.
          //   2. NOT also pushing `-lc++` here (the BoringSSL block
          //      below pushes it, which resolves to Apple's system
          //      libc++ providing the `__1` symbols).
          //
          // Without (1), V8 can't find its `__Cr` symbols. Without
          // (2), BoringSSL can't find its `__1` symbols. Both libs
          // coexist on the link line because the symbols are in
          // separate namespaces, so no duplicate-symbol conflict.
          if (engine === "v8") {
            const v8A = path.join(engineBuild, "libv8.a");
            if (existsSync(v8A)) {
              const flag = shortPath(v8A);
              if (!allLinkLibs.includes(flag)) allLinkLibs.push(flag);
            }
            const v8Cxx = path.join(engineBuild, "libc++.a");
            if (existsSync(v8Cxx)) {
              const flag = shortPath(v8Cxx);
              if (!allLinkLibs.includes(flag)) allLinkLibs.push(flag);
            }
          }
          // QuickJS and mQJS produce a separate libqjs.a / libmqjs.a
          // alongside libjs.a; both need linking.
          if (engine === "quickjs") {
            allLinkSearchDirs.push(shortPath(
              path.join(bareBuild, "_deps", "github+quickjs-ng+quickjs-build")
            ));
            // C++ runtime: Apple links libc++; the MinGW link (gcc
            // driver, see the Windows pin in ensureBareBuilt) needs
            // libstdc++ spelled explicitly.
            allLinkLibs.push("-lqjs", target === "windows" ? "-lstdc++" : "-lc++");
          }
          if (engine === "mqjs") {
            allLinkLibs.push("-lmqjs");
          }
          if (engine === "hermes") {
            // libhermes pins BUILD_SHARED_LIBS=OFF (see
            // libhermes/CMakeLists.txt), so Hermes produces static
            // archives. On Apple, HERMES_BUILD_APPLE_FRAMEWORK
            // defaults ON and Hermes wraps libhermesvm.a as a
            // framework bundle whose binary IS a static archive.
            // Apple's ld can link this via `-framework hermesvm`.
            const hermesBuildRoot = path.join(bareBuild, "_deps", "github+facebook+hermes-build");
            const hermesVmFwkCandidates = [
              path.join(hermesBuildRoot, "API", "hermes", "hermesvm.framework"),
              path.join(bareBuild, "lib", "hermesvm.framework"),
            ];
            const hermesVmFwk = hermesVmFwkCandidates.find(p => existsSync(p));
            const hermesVmLibA = path.join(hermesBuildRoot, "API", "hermes", "libhermesvm.a");
            if (hermesVmFwk) {
              allLinkLibs.push("-F" + shortPath(path.dirname(hermesVmFwk)));
              allLinkLibs.push("-framework", "hermesvm");
            } else if (existsSync(hermesVmLibA)) {
              const flag = shortPath(hermesVmLibA);
              if (!allLinkLibs.includes(flag)) allLinkLibs.push(flag);
            }
            // jsi follows BUILD_SHARED_LIBS / HERMES_BUILD_SHARED_JSI
            // — libhermes pins both OFF, so we get libjsi.a.
            const jsiLibA = path.join(hermesBuildRoot, "jsi", "libjsi.a");
            const jsiLibDylib = path.join(hermesBuildRoot, "jsi", "libjsi.dylib");
            if (existsSync(jsiLibA)) {
              const flag = shortPath(jsiLibA);
              if (!allLinkLibs.includes(flag)) allLinkLibs.push(flag);
            } else if (existsSync(jsiLibDylib)) {
              allLinkSearchDirs.push(shortPath(path.dirname(jsiLibDylib)));
              allLinkLibs.push("-ljsi");
            }
            // Hermes' framework binary only contains symbols from
            // API/hermes/*.cpp — not the underlying VM, optimizer,
            // parser, or LLVH support libraries. Those live as
            // ~25 separate static archives under `_deps/.../lib/*`
            // and `_deps/.../external/llvh/lib/*`.
            //
            // cmake's transitive PRIVATE link deps don't propagate
            // when we're linking by hand. Putting all 25 paths on
            // a single `//> link:` directive overflows Zen-C's
            // 8KB `g_link_flags` buffer (the buffer would be fine
            // for 25 short -l<name> entries, but our paths are
            // ~95 chars each → 2.4 KB just for these — and the
            // strncat-based accumulator in append_flag silently
            // truncates the last few paths instead of erroring).
            //
            // Solution: merge them into one combined archive via
            // libtool at build-config time, then link only that.
            // Static archive merge is cheap (just an `ar` table
            // rebuild — no compilation) and the resulting file is
            // dead-stripped by ld at the final link.
            const hermesLibGlobs = [
              path.join(hermesBuildRoot, "lib"),
              path.join(hermesBuildRoot, "external"),
              path.join(hermesBuildRoot, "public", "hermes", "Public"),
            ];
            const walkForA = (dir: string, out: string[]) => {
              if (!existsSync(dir)) return;
              const fs = require("fs") as typeof import("fs");
              for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
                const p = path.join(dir, entry.name);
                if (entry.isDirectory()) walkForA(p, out);
                else if (entry.isFile() && /^lib(hermes|LLVH|dtoa)[A-Za-z0-9]*\.a$/.test(entry.name)) {
                  out.push(p);
                }
              }
            };
            const hermesArchives: string[] = [];
            for (const root of hermesLibGlobs) walkForA(root, hermesArchives);
            if (hermesArchives.length > 0) {
              const combinedPath = path.join(hermesBuildRoot, "libhermes_combined.a");
              const fs = require("fs") as typeof import("fs");
              const newest = Math.max(...hermesArchives.map(p => fs.statSync(p).mtimeMs));
              const stale = !existsSync(combinedPath) || fs.statSync(combinedPath).mtimeMs < newest;
              if (stale) {
                const { execFileSync } = require("child_process") as typeof import("child_process");
                if (existsSync(combinedPath)) fs.unlinkSync(combinedPath);
                execFileSync("libtool", ["-static", "-o", combinedPath, ...hermesArchives], { stdio: "inherit" });
              }
              const flag = shortPath(combinedPath);
              if (!allLinkLibs.includes(flag)) allLinkLibs.push(flag);
            }
            // Hermes is C++ — pulls in std symbols. Uses the stock
            // libc++ namespace `__1`, so system libc++ is correct.
            if (!allLinkLibs.includes("-lc++")) allLinkLibs.push("-lc++");
          }
          // Bare's stdlib modules (bare-buffer, bare-os, bare-timers,
          // bare-buffer, etc.) live as separate binding.c.o objects
          // outside libbare.a. Each registers itself with the runtime
          // via a static-init constructor, which means we need
          // -force_load so the linker keeps the .o even though no
          // symbol from it is referenced from our code. Without this
          // bare.js fails on `require('bare-buffer')` and the runtime
          // crashes during bare_setup. The combined archive is built
          // in cli/src/native.ts after the bare cmake build.
          const libBareModules = path.join(bareBuild, "libbare_modules.a");
          if (existsSync(libBareModules)) {
            if (target === "windows") {
              // GNU ld spelling of force_load.
              allLinkLibs.push(
                "-Wl,--whole-archive",
                shortPath(libBareModules),
                "-Wl,--no-whole-archive",
              );
            } else {
              allLinkLibs.push(`-Wl,-force_load,${shortPath(libBareModules)}`);
            }
          }

          // Several bare-* bindings have heavyweight transitive
          // C deps that bare's cmake fetches but doesn't bundle into
          // libbare.a. When the corresponding binding.c.o is in
          // libbare_modules.a (because we now build bare_bin in
          // ensureBareBuilt), we ALSO need to put those deps on the
          // link line.
          //
          //   bare-tls / bare-crypto → BoringSSL (libssl + libcrypto
          //                            + libdecrepit). Symbols like
          //                            BIO_clear_retry_flags.
          //   bare-dns               → c-ares (libcares). Symbols
          //                            like ares_destroy.
          //   bare-zlib              → zlib (libz). Symbols like
          //                            deflateInit_ / inflate.
          //
          // The .a files live in different roots depending on which
          // cmake project built them:
          //   - macOS: vendor/bare's main build dir (bare_bin's
          //     transitive fetches).
          //   - iOS: the user-modules overlay (bare_bin isn't built
          //     on iOS, so the overlay re-fetches them via its own
          //     link_bare_module calls for bare-tcp/tls/dns/etc.).
          //
          // Probe both. We don't gate on which modules are present —
          // unused libs cost nothing because the linker dead-strips
          // unreferenced sections.
          const depRoots = [
            path.join(bareBuild, "_deps"),
            path.join(bareBuild, "zapp-user-modules", "build", "_deps"),
          ];
          for (const depRoot of depRoots) {
            const boringsslDir = path.join(depRoot, "github+google+boringssl-build");
            if (existsSync(path.join(boringsslDir, "libssl.a"))) {
              const dir = shortPath(boringsslDir);
              if (!allLinkSearchDirs.includes(dir)) allLinkSearchDirs.push(dir);
              if (!allLinkLibs.includes("-lssl")) {
                allLinkLibs.push("-lssl", "-lcrypto", "-ldecrepit");
              }
              // BoringSSL is C++ — pulls in std::__sort, std::terminate,
              // etc. The final binary is linked with clang (C), so we
              // need libc++ explicitly, and CRUCIALLY it has to come
              // AFTER the BoringSSL libs. Apple's ld doesn't re-scan
              // static archives once it passes them, so a `-lc++`
              // pushed earlier (e.g. by the V8 engine branch at
              // engine === "v8") doesn't satisfy libssl's references.
              //
              // Pull any existing `-lc++` out of the list first, then
              // re-push it here. Idempotent in the dedup sense, but
              // order-sensitive — which is the whole point.
              const cxxLib = target === "windows" ? "-lstdc++" : "-lc++";
              const cppIdx = allLinkLibs.indexOf(cxxLib);
              if (cppIdx >= 0) allLinkLibs.splice(cppIdx, 1);
              allLinkLibs.push(cxxLib);
            }
            const caresLib = path.join(depRoot, "github+c-ares+c-ares-build", "src", "lib", "libcares.a");
            if (existsSync(caresLib)) {
              const flag = shortPath(caresLib);
              if (!allLinkLibs.includes(flag)) allLinkLibs.push(flag);
            }
            // zlib's cmake names the static archive libz.a on Unix but
            // libzlibstatic.a on Windows (to avoid clashing with the
            // import lib of the DLL it also builds).
            for (const zlibName of ["libz.a", "libzlibstatic.a"]) {
              const zlibLib = path.join(depRoot, "github+madler+zlib-build", zlibName);
              if (existsSync(zlibLib)) {
                const flag = shortPath(zlibLib);
                if (!allLinkLibs.includes(flag)) allLinkLibs.push(flag);
                break;
              }
            }
          }
        }
      }
    }
  }

  // Flush all accumulated -L paths + -l flags as a single //> link:
  // directive. Single-line is the form zc handles cleanly — splitting
  // search paths into //> lib: directives or libs into multiple //>
  // link: lines caused only the first to be honored in tests on
  // zc v0.4.3.
  if (allLinkLibs.length > 0 || allLinkSearchDirs.length > 0) {
    // GNU ld (Windows/MinGW) resolves archives in a single left-to-right
    // pass, so the whole-archive modules .a can't see symbols from
    // -lutf/-lbare listed before it. --start/end-group makes ld iterate
    // the set to a fixed point — order-insensitive like Apple's ld.
    const libs = target === "windows"
      ? ["-Wl,--start-group", ...allLinkLibs, "-Wl,--end-group"]
      : allLinkLibs;
    const allFlags = [
      ...allLinkSearchDirs.map(d => `-L${d}`),
      ...libs,
    ];
    if (target === "windows") {
      // zc accumulates ALL link directives into a fixed 1024-byte
      // buffer (compiler_config.h link_flags) and silently truncates —
      // with the bare engine's full dep set this line alone is ~900
      // chars and truncation ate flags mid-token ("-lwindowscodecs" →
      // "lwindowscodecs"). Route the long dynamic set through a GCC
      // response file: gcc expands @file natively and the directive
      // stays ~30 chars. (Vendor ledger: Zen-C should grow the buffer.)
      windowsRspFlags.push(...allFlags.map(f => f.replace(/\\/g, "/")));
    } else {
      content += `//> link: ${allFlags.join(" ")}\n`;
    }
  }

  // zjs engine — independent of bare. Auto-builds the right libzjs
  // artifact if missing (one `make -C vendor/zjs [target]` invocation;
  // zjs's own Makefile handles the rest), then emits the include + link
  // directives. macOS + iOS Simulator today — Linux / Windows plumbing
  // follows once zjs ships uv-free platform shims for those targets or
  // we vendor libuv ourselves.
  //
  // iOS device (`ios-device`) is intentionally NOT covered yet — the
  // device toolchain build path is a separate follow-up (the kqueue-
  // apple branch scopes to Simulator only).
  // Windows: zjs ships Windows parity (libuv loop on the zapp side,
  // winhttp/ws2_32-backed platform layer on the zjs side). The library
  // artifact is an "embed-friendly" archive mirroring the iOS approach:
  // zc-transpiled engine + windows platform objects merged via `ld -r`,
  // then objcopy --keep-global-symbol="zjs_*" so the zenc stdlib that
  // BOTH zapp and libzjs embed (Arena__/Vec__/…) can't collide at link.
  if (hasZjs && target === "windows") {
    const { resolveVendorDir } = await import("./paths");
    const vendorDir = resolveVendorDir();
    const zjsDir = path.join(vendorDir, "zjs");
    const winBuildDir = path.join(zjsDir, "build", "windows");
    const embedLib = path.join(winBuildDir, "libzjs_embed.a");

    if (!existsSync(embedLib)) {
      clog(0, "building vendor/zjs (Windows embed archive; first run)...");
      const fsp = await import("node:fs/promises");
      // Clean slate: zc transpile writes its output via rename, which
      // fails ("rename output: File exists") on Windows if a stale
      // libzjs.c lingers from an interrupted build. We only reach here
      // when the final archive is missing, so wiping is safe.
      await fsp.rm(winBuildDir, { recursive: true, force: true });
      await fsp.mkdir(winBuildDir, { recursive: true });

      // Each build step is silent unless it FAILS (or --verbose). zjs is
      // a first-class engine in the zapp workflow, so its first-build
      // toolchain output (zc transpile diagnostics, gcc lines, the
      // ps1's per-file embed log) shouldn't spam a default `bun run dev`.
      // On failure the captured output is attached to the error so the
      // diagnostic isn't lost.
      const verbose = getCliLevel() >= 1;
      const runStep = (cmd: string[], opts: { cwd?: string }, what: string) => {
        const r = Bun.spawnSync(cmd, {
          cwd: opts.cwd,
          stdout: verbose ? "inherit" : "pipe",
          stderr: verbose ? "inherit" : "pipe",
        });
        if (r.exitCode !== 0) {
          const out = verbose ? "" :
            (r.stdout?.toString() ?? "") + (r.stderr?.toString() ?? "");
          throw new Error(`[zapp] vendor/zjs ${what} failed (exit ${r.exitCode})` +
            (out ? `\n${out}` : ""));
        }
      };

      // 1. CLI build script — creates the std junction + stdlib .gen.h
      //    embeds (idempotent). Needs zc + MinGW gcc + python3 on PATH.
      runStep(["powershell", "-File", path.join(zjsDir, "scripts", "build-windows.ps1")],
        { cwd: zjsDir }, "build-windows.ps1");
      // 2. Transpile the library entry. -q (quiet): the zjs engine
      //    source emits hundreds of zc warnings; -q suppresses them at
      //    the source. It ALSO fixes a zc quirk where warnings bump the
      //    exit code to 1 whenever stderr is redirected (not a console),
      //    which would otherwise fail this step under captured output.
      const libC = path.join(winBuildDir, "libzjs.c");
      runStep(["zc", "transpile", "-q", "-w", "--release", "-Isrc", "src/lib.zc", "-o", libC],
        { cwd: zjsDir }, "zc transpile lib.zc");
      // 3. Compile engine + windows platform + qjs-regex objects.
      const zcRoot = process.env.ZC_ROOT ?? path.dirname(Bun.which("zc") ?? "zc");
      const qjsre = path.join(zjsDir, "src", "third-party", "qjs-regex");
      const cflags = ["-O2", "-w", "-ffunction-sections", "-fdata-sections",
        `-I${path.join(zjsDir, "src")}`, `-I${zcRoot}`,
        `-I${path.join(zcRoot, "std", "third-party", "tre", "include")}`,
        `-I${qjsre}`, "-DCONFIG_ALL_UNICODE"];
      const units: Array<[string, string]> = [
        [libC, "libzjs.o"],
        [path.join(zjsDir, "src", "platform", "http_windows.c"), "http_windows.o"],
        [path.join(zjsDir, "src", "platform", "ws_windows.c"), "ws_windows.o"],
        [path.join(zjsDir, "src", "platform", "process_windows.c"), "process_windows.o"],
        [path.join(zjsDir, "src", "platform", "socket_windows.c"), "socket_windows.o"],
        [path.join(zjsDir, "src", "platform", "qjs_regex_shim.c"), "qjs_regex_shim.o"],
        [path.join(qjsre, "libregexp.c"), "qjs_libregexp.o"],
        [path.join(qjsre, "libunicode.c"), "qjs_libunicode.o"],
      ];
      const objs: string[] = [];
      for (const [src, obj] of units) {
        const out = path.join(winBuildDir, obj);
        runStep(["gcc", ...cflags, "-c", src, "-o", out], {}, `compile ${path.basename(src)}`);
        objs.push(out);
      }
      // 4. Merge + localize + archive.
      const embedObj = path.join(winBuildDir, "libzjs_embed.o");
      runStep(["ld", "-r", ...objs, "-o", embedObj], {}, "ld -r merge");
      runStep(["objcopy", "--wildcard", "--keep-global-symbol=zjs_*", embedObj], {}, "objcopy localize");
      runStep(["ar", "rcs", embedLib, embedObj], {}, "ar archive");
      clog(0, "vendor/zjs Windows embed archive built");
    }

    content += `//> cflags: -I${shortPath(path.join(zjsDir, "include"))}\n`;

    // zapp's engine host (native/worker/engines/zjs.c) drives a libuv
    // loop per worker on non-Apple platforms — reuse the libuv that the
    // bare engine build already produced. A zjs-only app on a machine
    // with no bare build yet has no libuv: vendoring libuv standalone
    // is the documented follow-up (WINDOWS_PORTING.md zjs ledger row).
    const { resolveBareDir } = await import("./paths");
    const bareDir = await resolveBareDir();
    let uvInclude = "";
    let uvLib = "";
    const bareBuilds = ["build-windows-quickjs", "build-windows-v8", "build-windows-mqjs", "build-windows-hermes"];
    for (const b of bareBuilds) {
      const inc = path.join(bareDir, b, "_deps", "github+libuv+libuv-src", "include");
      const lib = path.join(bareDir, b, "_deps", "github+libuv+libuv-build", "libuv.a");
      if (existsSync(inc) && existsSync(lib)) { uvInclude = inc; uvLib = lib; break; }
    }
    if (!uvInclude) {
      throw new Error(
        "[zapp] zjs on Windows needs libuv headers + libuv.a; none found under " +
        "vendor/bare/build-windows-*/. Build any bare engine once (or wait for " +
        "the vendored-libuv follow-up).");
    }
    content += `//> cflags: -I${shortPath(uvInclude)}\n`;

    // Link args ride the same response file as the bare set (the zc
    // link-directive buffer is 1024 bytes — see the rsp note above).
    // -lz: MinGW-w64 bundles libz (zjs node:zlib). The rest mirror
    // src/lib.zc's //> windows: link: line.
    // System import libs repeated AFTER libuv.a: GNU ld is single-pass
    // and zjs pulls libuv members (process.c → dbghelp/userenv,
    // util.c → iphlpapi) that the base `//> windows: link:` line —
    // which precedes the rsp — can't satisfy retroactively.
    windowsRspFlags.push(
      shortPath(embedLib).replace(/\\/g, "/"),
      shortPath(uvLib).replace(/\\/g, "/"),
      "-lwinhttp", "-lws2_32", "-lbcrypt", "-lpsapi", "-lz",
      "-ldbghelp", "-liphlpapi", "-luserenv",
    );
  }

  if (hasZjs && (target === "macos" || target === "ios-simulator")) {
    const { resolveVendorDir } = await import("./paths");
    const vendorDir = resolveVendorDir();
    const zjsDir = path.join(vendorDir, "zjs");
    const zjsInclude = path.join(zjsDir, "include");

    // Branch make invocation + output artifact by target.
    //
    // macOS: link the dylib, not the .a. Both the framework and
    //   libzjs.a embed zenc's stdlib (Vec / String / Option / Arena / …)
    //   — linking the .a fails with hundreds of duplicate-symbol errors
    //   on those shared internals. The dylib resolves symbols per-binary,
    //   so the framework sees only zjs's exported zjs_* surface and its
    //   own copy of the stdlib stays unconflicted.
    //
    //   Long-term fix lives upstream in zjs: ship an embed-friendly .a
    //   with internal symbols stripped (ld -r + -unexported_symbols_list,
    //   or build a relocatable .o with `-hidden`). Until then the dylib
    //   is the right pragmatic choice — runtime dylib dependency is
    //   acceptable since libzjs.dylib lives next to the binary in dev
    //   and bundles into the .app in prod.
    //
    // iOS Simulator: same duplicate-symbol risk as macOS would have
    //   with the .a, but dylibs aren't viable on iOS (Apple's toolchain
    //   expects third-party native libs to link statically into the
    //   app binary). We work around it by post-processing libzjs.a
    //   into an "embed-friendly" archive (libzjs_embed.a) where every
    //   non-`_zjs_*` symbol is `ld -r`'d into a single relocatable
    //   .o with private-extern visibility (`-exported_symbols_list`
    //   restricted to `_zjs_*`). The framework only ever calls into
    //   `zjs_*`, so hiding the rest is safe — and the framework's own
    //   copy of zenc's stdlib (Arena / Vec / String / …) wins the link.
    //   See the build step below the install_name section.
    let zjsLib: string;
    let makeCmd: string[];
    let buildLabel: string;
    if (target === "ios-simulator") {
      zjsLib = path.join(zjsDir, "build", "ios", "simulator-arm64", "libzjs.a");
      makeCmd = ["make", "-C", zjsDir, "ios-simulator-arm64"];
      buildLabel = "vendor/zjs (iOS Sim arm64; first run; ~30s)";
    } else {
      // target === "macos"
      zjsLib = path.join(zjsDir, "build", "libzjs.dylib");
      makeCmd = ["make", "-C", zjsDir];
      buildLabel = "vendor/zjs (first run; ~30s)";
    }

    if (!existsSync(zjsLib)) {
      clog(1, `building ${buildLabel}...`);
      const proc = Bun.spawn(makeCmd, {
        stdout: "pipe", stderr: "pipe",
      });
      const exitCode = await proc.exited;
      if (exitCode !== 0 || !existsSync(zjsLib)) {
        const stderr = await new Response(proc.stderr).text();
        throw new Error(
          `[zapp] failed to build vendor/zjs (exit ${exitCode}). ` +
          `Tried: ${makeCmd.join(" ")}. Build vendor/zjs by hand and rerun.\n${stderr}`
        );
      }
    }

    // install_name_tool rewrite is macOS-only — iOS uses a static .a,
    // which has no install_name (it's a dylib-only concept).
    //
    // zjs's Makefile bakes a relative install_name ("build/libzjs.dylib")
    // because the dylib is normally consumed in-tree (its own smoke test
    // run from the project root finds it via @loader_path). For Zapp
    // we're linking from a different cwd, so the runtime loader can't
    // resolve the relative path. Rewrite the install_name to the
    // absolute vendor location once — idempotent, fast, no rebuild.
    if (target === "macos") {
      const otoolD = Bun.spawnSync(["otool", "-D", zjsLib]);
      const installName = new TextDecoder().decode(otoolD.stdout).split("\n")[1]?.trim();
      if (installName && installName !== zjsLib) {
        const fix = Bun.spawnSync(["install_name_tool", "-id", zjsLib, zjsLib]);
        if (fix.exitCode !== 0) {
          throw new Error(
            `[zapp] failed to set absolute install_name on ${zjsLib}: ` +
            new TextDecoder().decode(fix.stderr)
          );
        }
      }
    }

    // Headers: zjs's own. The Apple loop in engines/zjs.c is kqueue +
    // CFRunLoop (Task 2 of the kqueue-apple migration), so libuv is no
    // longer a build- or runtime-time dependency on Apple. Linux /
    // Windows zjs ports will reintroduce libuv (or an equivalent shim)
    // under their own platform branches when they land.
    //
    // Per-target framework + link emission:
    //   macOS: -rpath so the framework binary finds libzjs.dylib at
    //     runtime from the vendor build dir. Production builds will
    //     copy the dylib into the .app bundle's Frameworks dir and use
    //     @loader_path instead — Z5 follow-up. CoreFoundation
    //     (CFRunLoopRunInMode) is already in the unconditional macOS
    //     framework set above. Foundation (NSURLSession in zjs's
    //     http_apple.m + ws_apple.m) is not, so we add it here scoped
    //     to the zjs branch.
    //   iOS: no rpath — static lib links directly into the binary.
    //     Foundation is already in the iOS unconditional framework set
    //     (every iOS .m source imports <Foundation/Foundation.h>);
    //     CoreFoundation is brought in transitively by Foundation on
    //     iOS, so neither needs to be re-emitted here.
    //
    // iOS directives use NO platform prefix (mirrors the iOS branch
    // above). zc filters platform-prefixed directives by HOST
    // platform, not build target — so `//> ios:` on a macOS host
    // would get dropped. Plain `//> cflags:` / `//> link:` bypass
    // the filter and apply unconditionally, which is what we want
    // for an iOS build running on a macOS host.
    if (target === "ios-simulator") {
      // Produce an embed-friendly archive: ld -r merges libzjs.a's
      // objects into a single relocatable .o, then `-exported_symbols_list`
      // restricts globally-visible symbols to `_zjs_*`. Every other
      // symbol (Arena__*, Vec__*, the zenc-stdlib runtime that both
      // Zapp's framework and libzjs.a embed) becomes a private extern,
      // resolved within the merged .o and invisible to the final ld
      // pass. That sidesteps the ~37 duplicate-symbol clashes between
      // libzjs.a's stdlib copy and the framework's stdlib copy.
      //
      // Cached by mtime — re-runs after the first build are no-ops.
      const sdkPath = await resolveSDKPath("iphonesimulator");
      const versionMinFlag = "-mios-simulator-version-min=15.0";
      const iosBuildDir = path.join(zjsDir, "build", "ios", "simulator-arm64");
      const embedLib = path.join(iosBuildDir, "libzjs_embed.a");
      const embedObj = path.join(iosBuildDir, "libzjs_embed.o");
      const symsList = path.join(iosBuildDir, "libzjs_embed.syms");
      // Sources libzjs.a REFERENCES but vendor zjs's iOS Makefile target
      // doesn't compile (file upstream; built here until fixed):
      //   - aes-gcm/aes_gcm.c        → zjs_pc_aes_gcm_*
      //   - platform/process_posix.c → zjs_process_spawn_capture
      //     (child_process host API added in the Windows-parity sprint)
      const extraSrcs = [
        path.join(zjsDir, "src", "third-party", "aes-gcm", "aes_gcm.c"),
        path.join(zjsDir, "src", "platform", "process_posix.c"),
      ].filter((p) => existsSync(p));
      const fs = await import("node:fs");
      const srcMtime = fs.statSync(zjsLib).mtimeMs;
      const extraMtime = Math.max(0, ...extraSrcs.map((p) => fs.statSync(p).mtimeMs));
      const stale = !existsSync(embedLib)
        || fs.statSync(embedLib).mtimeMs < srcMtime
        || fs.statSync(embedLib).mtimeMs < extraMtime;
      if (stale) {
        clog(1, "post-processing libzjs.a → libzjs_embed.a (iOS Sim)...");

        // Compile each missing source into an object for the ld -r merge
        // so the merged .o is self-contained.
        const extraObjs: string[] = [];
        for (const src of extraSrcs) {
          const obj = path.join(iosBuildDir, path.basename(src).replace(/\.c$/, ".o"));
          const cc = Bun.spawnSync([
            "clang",
            "-O3",
            "-arch", "arm64",
            "-isysroot", sdkPath,
            versionMinFlag,
            "-I" + path.join(zjsDir, "src"),
            "-c", src,
            "-o", obj,
          ]);
          if (cc.exitCode !== 0) {
            throw new Error(
              `[zapp] failed to compile ${path.basename(src)} for iOS Sim: ` +
              new TextDecoder().decode(cc.stderr)
            );
          }
          extraObjs.push(obj);
        }

        // The exported-symbols list is a single-pattern file matching
        // every `_zjs_*` symbol. `*` is the glob meta in ld's
        // -exported_symbols_list grammar.
        await Bun.write(symsList, "_zjs_*\n");
        const ldArgs = [
          "-r",
          "-arch", "arm64",
          "-platform_version", "ios-simulator", "15.0", "15.0",
          "-syslibroot", sdkPath,
          "-exported_symbols_list", symsList,
          // Force-load every .o in the .a — ld -r otherwise skips
          // unreferenced objects, which would lose half of libzjs.
          "-force_load", zjsLib,
          ...extraObjs,
          "-o", embedObj,
        ];
        const ld = Bun.spawnSync(["ld", ...ldArgs]);
        if (ld.exitCode !== 0) {
          throw new Error(
            `[zapp] failed to build libzjs_embed.o: ` +
            new TextDecoder().decode(ld.stderr)
          );
        }
        if (existsSync(embedLib)) fs.unlinkSync(embedLib);
        const ar = Bun.spawnSync(["ar", "-rcs", embedLib, embedObj]);
        if (ar.exitCode !== 0) {
          throw new Error(
            `[zapp] failed to repack libzjs_embed.a: ` +
            new TextDecoder().decode(ar.stderr)
          );
        }
      }
      content += `//> cflags: -I${shortPath(zjsInclude)}\n`;
      // Security.framework — `SecRandomCopyBytes` (used by zjs's
      // crypto.subtle key-generation path) lives there. Already in
      // the macOS unconditional framework set above; iOS's
      // unconditional set doesn't include it, so we add it here
      // scoped to the zjs branch.
      content += `//> framework: Security\n`;
      // aes_gcm.c is folded into the embed .o above (vendor zjs's
      // iOS Makefile target misses it — see the embed step). No
      // separate cflags entry needed here.
      content += `//> link: ${shortPath(embedLib)}\n`;
    } else {
      // target === "macos"
      const zjsBuildDir = path.dirname(zjsLib);
      content += `//> macos: cflags: -I${shortPath(zjsInclude)}\n`;
      content += `//> macos: framework: Foundation\n`;
      content += `//> macos: link: ${shortPath(zjsLib)} -Wl,-rpath,${zjsBuildDir}\n`;
    }
  }

  if (process.platform === "win32" && sources.length > 0) {
    // WebView2 SDK include path (self-contained loader — no WebView2Loader.dll needed)
    const vendorDir = resolveVendorDir();
    const webview2Dir = path.join(vendorDir, "webview2");
    const webview2Include = path.join(webview2Dir, "include");
    // -DUNICODE / -D_UNICODE / -DCINTERFACE / -DCOBJMACROS are
    // boilerplate every Win32 + COM/WebView2 app needs — emit here
    // so user `build.zc` doesn't have to know.
    const winSources = [...sources, ...resolvedUserSources];
    content += `//> windows: cflags: -DUNICODE -D_UNICODE -DCINTERFACE -DCOBJMACROS ${winSources.map(shortPath).join(" ")} -I${shortPath(webview2Include)}\n`;
    // Standard Win32 + WebView2 link set — every app needs these,
    // additional libs go in `extraLinkFlags.windows` in zapp.config.ts.
    content += `//> windows: link: -lole32 -lshell32 -luuid -luser32 -lgdi32 -lcomctl32 -lcomdlg32 -lshlwapi\n`;
    content += `//> windows: link: -lwinhttp -lbcrypt -ladvapi32 -lrpcrt4 -lcrypt32 -lversion\n`;
    // libuv (via bare) and BoringSSL system deps. Harmless when no
    // worker engine is compiled in — unreferenced import libs are
    // dropped by the linker.
    content += `//> windows: link: -lws2_32 -liphlpapi -luserenv -ldbghelp -lpsapi\n`;
    // windowscodecs: WIC PNG codec for clipboard image read/write.
    // shcore: GetDpiForMonitor for screen.c's scaleFactor.
    // runtimeobject: WinRT activation + HSTRING (toast notifications).
    // dwmapi: DwmSetWindowAttribute for Mica/Acrylic + dark caption (material.c).
    content += `//> windows: link: -lwindowscodecs -lshcore -lruntimeobject -ldwmapi\n`;
    // App-declared extras from zapp.config.ts. `extraFrameworks` is
    // a no-op here (Apple-only concept); use `extraLinkFlags.windows`
    // for `-l<name>` and similar.
    if (userExtraLinkFlags.length > 0) {
      content += `//> windows: link: ${userExtraLinkFlags.join(" ")}\n`;
    }
  }

  if (target === "windows" && windowsRspFlags.length > 0) {
    const rspPath = path.join(zappDir, "zapp_link.rsp");
    await Bun.write(rspPath, windowsRspFlags.join(" ") + "\n");
    content += `//> link: @${shortPath(rspPath).replace(/\\/g, "/")}\n`;
  }

  const outPath = path.join(zappDir, "zapp_platform.zc");
  await Bun.write(outPath, content);
  return outPath;
}
