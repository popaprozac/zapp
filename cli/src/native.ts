// Native compilation — compiles with zc.

import path from "node:path";
import { existsSync, unlinkSync } from "node:fs";
import { readdir } from "node:fs/promises";
import { resolveBareDir } from "./paths";
import { clog } from "./log";

/**
 * Build target — what platform/architecture the binary is being
 * compiled FOR. Distinct from the host platform we're building ON
 * (always darwin for iOS targets — Xcode SDK requirement).
 */
export type BuildTarget = "macos" | "ios-simulator" | "ios-device" | "windows";

/**
 * Detect the build target from CLI argv. `--platform ios` is sugar
 * for ios-simulator (the common dev case); use `ios-device` explicitly
 * for App Store / TestFlight builds. Without a flag, defaults to the
 * host platform.
 */
export function detectTarget(argv: string[] = process.argv): BuildTarget {
  const idx = argv.indexOf("--platform");
  const explicit = idx >= 0 ? argv[idx + 1] : null;
  if (explicit) {
    if (explicit === "ios" || explicit === "ios-simulator") return "ios-simulator";
    if (explicit === "ios-device") return "ios-device";
    if (explicit === "macos" || explicit === "darwin") return "macos";
    if (explicit === "windows" || explicit === "win32") return "windows";
    throw new Error(`[zapp] unknown --platform '${explicit}'. Expected one of: macos, ios, ios-simulator, ios-device, windows.`);
  }
  if (process.platform === "darwin") return "macos";
  if (process.platform === "win32") return "windows";
  return "macos";
}

/** True when the target is any iOS variant (simulator or device). */
export function isIOSTarget(t: BuildTarget): boolean {
  return t === "ios-simulator" || t === "ios-device";
}

/**
 * Get the platform-specific .m / .c files to compile for a given target.
 * Falls through to host platform when the target's source dir doesn't
 * exist yet (iOS during the initial port).
 */
export function getPlatformSources(nativeDir: string, target: BuildTarget = detectTarget()): string[] {
  if (target === "macos") {
    const darwinDir = path.join(nativeDir, "platform", "darwin");
    const sources = [
      path.join(darwinDir, "platform.m"),
      path.join(darwinDir, "window.m"),
      path.join(darwinDir, "webview.m"),
      path.join(darwinDir, "dialog.m"),
      path.join(darwinDir, "menu.m"),
      path.join(darwinDir, "notification.m"),
      path.join(darwinDir, "sync.m"),
      path.join(darwinDir, "dock.m"),
      path.join(darwinDir, "tray.m"),
      path.join(darwinDir, "fs.m"),
      path.join(darwinDir, "clipboard.m"),
      path.join(darwinDir, "shortcuts.m"),
      path.join(darwinDir, "panel.m"),
      path.join(darwinDir, "sidebar.m"),
      path.join(darwinDir, "toolbar.m"),
      path.join(darwinDir, "popover.m"),
      path.join(darwinDir, "screen.m"),
    ];
    // bare.c / zjs.c are NOT listed here — they're added by
    // `generatePlatformConfig` only when the corresponding
    // ZAPP_WORKER_ENGINE_* directive is enabled.
    return sources.filter(f => existsSync(f));
  }
  if (isIOSTarget(target)) {
    const iosDir = path.join(nativeDir, "platform", "ios");
    // Mirrors the darwin/ source list — every file here is the iOS
    // counterpart of the same-named darwin/ file. Symbols match
    // (darwin_window_create, darwin_clipboard_read_text, etc.) so
    // the Zen-C framework calls bind unchanged across platforms.
    //
    // Worker engines (bare.c, zjs.c) are gated in
    // `generatePlatformConfig` and only added when the
    // corresponding ZAPP_WORKER_ENGINE_* directive is set.
    const sources = [
      path.join(iosDir, "platform.m"),
      path.join(iosDir, "window.m"),
      path.join(iosDir, "webview.m"),
      path.join(iosDir, "dialog.m"),
      path.join(iosDir, "menu.m"),
      path.join(iosDir, "notification.m"),
      path.join(iosDir, "sync.m"),
      path.join(iosDir, "dock.m"),
      path.join(iosDir, "tray.m"),
      path.join(iosDir, "fs.m"),
      path.join(iosDir, "clipboard.m"),
      path.join(iosDir, "shortcuts.m"),
      path.join(iosDir, "panel.m"),
      path.join(iosDir, "sidebar.m"),
      path.join(iosDir, "toolbar.m"),
      path.join(iosDir, "popover.m"),
      path.join(iosDir, "screen.m"),
    ];
    return sources.filter(f => existsSync(f));
  }
  if (target === "windows") {
    const windowsDir = path.join(nativeDir, "platform", "windows");
    const sources = [
      path.join(windowsDir, "platform.c"),
      path.join(windowsDir, "window.c"),
      path.join(windowsDir, "webview.c"),
      path.join(windowsDir, "dialog.c"),
      path.join(windowsDir, "menu.c"),
      path.join(windowsDir, "notification.c"),
      path.join(windowsDir, "sync.c"),
      path.join(windowsDir, "clipboard.c"),
      path.join(windowsDir, "screen.c"),
    ];
    return sources.filter(f => existsSync(f));
  }
  return [];
}

// Scan the project's zapp/ tree for user-authored ObjC/C sources.
// Convention: drop .m (macOS) or .c (Windows) files anywhere under
// <project>/zapp/**, reference them from your .zc service code, and the
// CLI will compile + link them alongside the framework's platform sources.
//
// Example: `zapp/services/keychain.m` + `zapp/services/keychain.h` gives
// you a pure-ObjC service that calls Security.framework, called from a
// Zen-C service handler via `import "services/keychain.h"`.
export async function getUserProjectSources(root: string, target: BuildTarget = detectTarget()): Promise<string[]> {
  const projectZapp = path.join(root, "zapp");
  if (!existsSync(projectZapp)) return [];

  // .m for any Apple platform (macOS + iOS), .c for Windows. iOS user
  // sources can also be ObjC; clang picks the right path via extension.
  const ext = (target === "macos" || isIOSTarget(target)) ? ".m"
    : target === "windows" ? ".c"
    : null;
  if (!ext) return [];
  const fileExt: string = ext;

  const results: string[] = [];
  async function walk(dir: string): Promise<void> {
    let entries;
    try { entries = await readdir(dir, { withFileTypes: true }); }
    catch { return; }
    for (const entry of entries) {
      if (entry.name.startsWith(".")) continue;
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        await walk(full);
      } else if (entry.isFile() && entry.name.endsWith(fileExt)) {
        results.push(full);
      }
    }
  }
  await walk(projectZapp);
  return results;
}


/** Bare's pluggable JS engine — picks the C library that backs `js.h`. */
export type BareEngine = "v8" | "jsc" | "quickjs" | "mqjs" | "hermes";

// Map BareEngine → cmake-fetch spec for `-DBARE_ENGINE=`. The libjs
// repo IS the V8 binding (Bare's upstream default); libjsc / libqjs /
// libmqjs are the alternate engines. `hermes` points at our in-house
// libhermes (popaprozac/libhermes) — not yet on github, so the cmake
// configure also receives a `-DFETCHCONTENT_SOURCE_DIR_*` override
// directing the fetch at the local checkout (see ensureBareBuilt).
function bareEngineSpec(engine: BareEngine): string {
  switch (engine) {
    case "v8":      return "github:holepunchto/libjs";
    case "jsc":     return "github:holepunchto/libjsc#main";
    case "quickjs": return "github:holepunchto/libqjs";
    case "mqjs":    return "github:holepunchto/libmqjs";
    case "hermes":  return "github:popaprozac/libhermes";
  }
}

// Local checkout path for libhermes — used by FETCHCONTENT_SOURCE_DIR
// to short-circuit cmake-fetch until the repo is published. Resolved
// relative to this file's location: `<zapp>/cli/src/` →
// `<zapp>/../popaprozac/libhermes/`.
function libhermesLocalPath(): string {
  // path here is the module-scope path import.
  return path.resolve(__dirname, "..", "..", "..", "popaprozac", "libhermes");
}

// Per-platform Zapp default — picked when a project enables workers
// (configures any `headless` entry, or uses `new Worker()` from JS)
// but doesn't name an engine. The defaults bias toward the smallest
// binary that fits the platform's constraints:
//
//   macOS / iOS — bare-jsc. JSC ships in the system framework, so the
//     engine itself adds zero binary weight. JIT on macOS (with the
//     allow-jit entitlement we auto-merge); no JIT on iOS by Apple
//     policy. The clear "free and fast" pick.
//
//   Windows / Linux — bare-quickjs. ~1.5 MB binary cost, no JIT
//     (interpreter only), but works everywhere with no platform
//     surprises. Apps that need JIT speed can opt into bare-v8
//     explicitly (~60 MB binary).
//
// The choice for Windows / Linux defaulting to QuickJS over V8
// matches Zapp's "small binary by default, opt in to size" pitch —
// same shape as the rest of the framework. Devs reaching for
// CPU-heavy worker code (ML, codecs, compute-bound services) should
// switch to `engine: "bare-v8"` per-worker.
//
// Apps can override per-worker via `engine: "..."` in
// zapp.config.ts. When workers aren't configured at all, NO engine
// is built — the binary stays tiny.
export function defaultBareEngine(target: BuildTarget): BareEngine {
  if (target === "macos" || isIOSTarget(target)) return "jsc";
  return "quickjs";
}

// Per-target + per-engine build dir. Engines build independently —
// shipping bare-jsc + bare-v8 in the same Zapp binary means two
// separate Bare static libs in two dirs. (Rare but possible if an
// app wants a JSC worker for one job and a V8 worker for another.)
export function bareBuildDirName(target: BuildTarget, engine: BareEngine): string {
  const platform = target === "ios-simulator" ? "ios-sim"
    : target === "ios-device" ? "ios-dev"
    : target;
  return `build-${platform}-${engine}`;
}

// Ensure Bare runtime is built (via cmake) for the given target +
// engine. Bare's CMakeLists drives engine fetch through cmake-fetch
// — so the first build pulls in the engine source + libuv + libutf
// via internal git clones. Subsequent builds reuse the cached
// `_deps/` tree.
//
// Bare requires `bun install` in its directory before cmake configure
// (its CMakeLists looks up cmake-bare / cmake-fetch / cmake-drive in
// node_modules). We run it on first build only.
export async function ensureBareBuilt(
  _nativeDir: string,
  target: BuildTarget = detectTarget(),
  engine: BareEngine = defaultBareEngine(target),
  projectRoot?: string,
): Promise<string> {
  const bareDir = await resolveBareDir();
  const buildDir = bareBuildDirName(target, engine);
  // libbare.a is the canonical artifact — when this exists the Bare
  // build succeeded for this (target, engine) combo.
  const libPath = path.join(bareDir, buildDir, "libbare.a");

  if (existsSync(libPath)) {
    // Even when libbare.a exists, we still need to make sure the
    // bare-* module bindings have been compiled. On macOS this means
    // building the `bare_bin` target — vendor/bare/bin/CMakeLists.txt
    // calls `link_bare_module(bare_bin bare-tcp/tls/dns/...)` which
    // forces those bindings' `binding.c.o` to compile, after which
    // `ensureBareModulesArchive` sweeps them into libbare_modules.a.
    //
    // On iOS, `bin/` is gated off (vendor/bare/CMakeLists.txt zapp
    // patch — bare_bin uses MACOSX_BUNDLE which fails cmake configure
    // for iOS install rules). We just rebuild bare_static. Apps that
    // need bare-tcp/tls/dns/zlib on iOS surface via the user-modules
    // overlay path (`workerModules: ["fetch"]` in zapp.config.ts).
    const bareTarget = isIOSTarget(target) || target === "windows" ? "bare_static" : "bare_bin";

    // Same split-build dance for Hermes — see the matching block
    // below in the first-build path. Idempotent: the downleveler
    // checks for a marker in the .h file and skips if already
    // lowered, so a hot incremental rebuild only re-runs the
    // bundle target (cheap) and the no-op downlevel check.
    if (engine === "hermes") {
      const bundleBuild = Bun.spawn(
        ["cmake", "--build", buildDir, "--target", "bare_bundle", "-j4"],
        { cwd: bareDir, stdout: "inherit", stderr: "inherit" },
      );
      if (await bundleBuild.exited !== 0) {
        throw new Error("[zapp] Bare cmake bare_bundle build failed");
      }
      const { downlevelBareJsForHermes } = await import("./downlevel-bare-js.js");
      await downlevelBareJsForHermes(bareDir);
    }

    const cmakeBin = Bun.spawn(
      ["cmake", "--build", buildDir, "--target", bareTarget, "-j4"],
      { cwd: bareDir, stdout: "inherit", stderr: "inherit" }
    );
    if (await cmakeBin.exited !== 0) {
      throw new Error(`[zapp] Bare ${bareTarget} incremental build failed`);
    }
    pruneBareSharedLib(path.join(bareDir, buildDir));
    // Compile any user-installed bare-* with native bindings that
    // vendor/bare doesn't already cover (e.g. bare-zlib).
    if (projectRoot) {
      await ensureUserBareModulesCompiled(bareDir, buildDir, projectRoot, target);
    }
    // Ensure the combined modules archive exists too — it's a
    // post-build step we own (cmake doesn't bundle the bare-*
    // module bindings into libbare.a).
    await ensureBareModulesArchive(path.join(bareDir, buildDir), projectRoot, target);
    return bareDir;
  }

  // Bare's CMakeLists requires its node_modules deps (cmake-bare,
  // cmake-fetch, cmake-drive, etc.) — install them on first build.
  if (!existsSync(path.join(bareDir, "node_modules", "cmake-bare"))) {
    clog(1, "installing Bare cmake dependencies...");
    const install = Bun.spawn(["bun", "install"], {
      cwd: bareDir, stdout: "inherit", stderr: "inherit",
    });
    if (await install.exited !== 0) throw new Error("[zapp] Bare bun install failed");
  }

  const label = target === "macos" ? "macOS"
    : target === "ios-simulator" ? "iOS Simulator (arm64)"
    : target === "ios-device" ? "iOS device (arm64)"
    : target;
  clog(0, `building Bare (${engine}) for ${label} (first time only, may take a few minutes)...`);

  const configureArgs = [
    "-B", buildDir,
    "-DCMAKE_BUILD_TYPE=Release",
    `-DBARE_ENGINE=${bareEngineSpec(engine)}`,
    // Prebuilds default ON and pulls a pinned V8 static library via a
    // Hyperdrive mirror. We only need that for the V8 engine path; for
    // JSC / QuickJS / mQJS / Hermes we build the engine from source.
    `-DBARE_PREBUILDS=${engine === "v8" ? "ON" : "OFF"}`,
  ];

  if (target === "windows") {
    // The whole app links with MinGW gcc (zc's default cc), so bare
    // must be MinGW too — MSVC-built C++ statics can't mix into a
    // MinGW link (different STL + CRT). Without this pin CMake picks
    // the Visual Studio generator when BuildTools are installed,
    // which also breaks every artifact path this file checks
    // (multi-config Release/ subdirs, bare.lib instead of libbare.a,
    // binding.c.obj instead of binding.c.o). Ninja + gcc gives the
    // same single-config flat layout as the macOS Makefile path.
    configureArgs.push(
      "-G", "Ninja",
      "-DCMAKE_C_COMPILER=gcc",
      "-DCMAKE_CXX_COMPILER=g++",
      // GCC 14+ promoted incompatible-pointer-types to an error;
      // vendored deps (libuv 1.52.1 src/win/util.c) still trip it.
      // Downgrade back to a warning — these are upstream's to fix.
      "-DCMAKE_C_FLAGS=-Wno-error=incompatible-pointer-types",
      // BoringSSL's fiat adx assembly only assembles for ELF/Apple —
      // on MinGW COFF the C code references fiat_p256_adx_mul/sqr but
      // nothing defines them and the final link fails. Pure-C crypto
      // until upstream grows MinGW asm support (slower EC ops only).
      "-DOPENSSL_NO_ASM=1",
    );
  }

  // (libhermes used to ship local-only here; now lives at
  // github:popaprozac/libhermes so cmake-fetch clones it like every
  // other engine. Leaving the local-path helper around for future
  // dev workflows — see `libhermesLocalPath` declaration above.)

  if (isIOSTarget(target)) {
    const sdk = target === "ios-simulator" ? "iphonesimulator" : "iphoneos";
    const proc = Bun.spawn(["xcrun", "--sdk", sdk, "--show-sdk-path"], { stdout: "pipe" });
    const sdkPath = (await new Response(proc.stdout).text()).trim();
    if (await proc.exited !== 0 || !sdkPath) {
      throw new Error(`[zapp] failed to resolve ${sdk} SDK path via xcrun`);
    }
    configureArgs.push(
      "-DCMAKE_SYSTEM_NAME=iOS",
      "-DCMAKE_SYSTEM_PROCESSOR=arm64",
      `-DCMAKE_OSX_SYSROOT=${sdkPath}`,
      "-DCMAKE_OSX_ARCHITECTURES=arm64",
      "-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0",
      // Skip `install(...)` rule validation. On iOS, vendor/bare's
      // `bin/CMakeLists.txt` and BoringSSL's CMakeLists declare
      // MACOSX_BUNDLE executables (bare_bin, bssl) and pass them to
      // `install(TARGETS ...)`. CMake fails configure on iOS because
      // those installs need a `BUNDLE DESTINATION` we don't provide
      // — but we NEVER `cmake --install`, only `cmake --build`. The
      // CMAKE_SKIP_INSTALL_RULES toggle drops the install commands
      // from generation entirely, sidestepping the validation.
      "-DCMAKE_SKIP_INSTALL_RULES=ON",
    );
    // Hermes-only iOS flags: skip Hermes' CLI tools (hermes, hermesc,
    // hdb, hbcdump, hvm, hcdp). They're declared MACOSX_BUNDLE
    // executables and `install(TARGETS ...)` cmake-validates at
    // configure time even with CMAKE_SKIP_INSTALL_RULES — fails with
    // "install TARGETS given no BUNDLE DESTINATION for MACOSX_BUNDLE
    // executable target". We don't run the tools in the iOS app
    // (no hermesc invocation in our build pipeline; we downlevel +
    // bundle JS via Vite + Babel pre-load), so this is pure dead
    // weight on iOS anyway. HERMES_ENABLE_TEST_SUITE has to come
    // along — Hermes errors out fatally when tests are on but
    // tools are off.
    //
    // BUT — Hermes' `lib/InternalBytecode/CMakeLists.txt` still needs
    // `hermesc` at build time to pre-compile its Promise/Symbol/
    // AsyncFn/ES6Class polyfill .js into the .hbc bytecode embedded
    // in libhermesInternalBytecode.a. Hermes' upstream cross-compile
    // path is `-DIMPORT_HOST_COMPILERS=<file>.cmake`, where the file
    // declares `native-hermesc` as an IMPORTED executable pointing
    // at a host-built hermesc. We do exactly that: recurse into
    // ensureBareBuilt for the macOS+hermes host first (idempotent —
    // skipped if libbare.a already exists), then write an import
    // shim pointing at vendor/bare/build-macos-hermes/bin/hermesc.
    if (engine === "hermes") {
      // Ensure the host (macOS) bare-hermes build exists so we have
      // a hermesc binary to point IMPORT_HOST_COMPILERS at. The
      // recursive call is idempotent — it short-circuits when
      // libbare.a is already there.
      await ensureBareBuilt(_nativeDir, "macos", "hermes", projectRoot);
      const hostHermesc = path.join(
        bareDir, "build-macos-hermes", "bin", "hermesc",
      );
      if (!existsSync(hostHermesc)) {
        throw new Error(
          `[zapp] iOS hermes build needs a macOS host hermesc at ${hostHermesc}, but none exists. ` +
          `Build the macOS hermes target first: \`bun run dev\` from the project root.`
        );
      }
      const importFile = path.join(bareDir, `zapp-host-tools-${engine}.cmake`);
      const importContent =
        `# Auto-generated by Zapp's CLI for iOS+Hermes cross-compile.\n` +
        `# Points Hermes' InternalBytecode build at a macOS-built hermesc\n` +
        `# (Hermes' standard IMPORT_HOST_COMPILERS pattern, also used by\n` +
        `# React Native's iOS build).\n` +
        `add_executable(native-hermesc IMPORTED)\n` +
        `set_target_properties(native-hermesc PROPERTIES\n` +
        `  IMPORTED_LOCATION "${hostHermesc}")\n`;
      const fs = await import("node:fs/promises");
      await fs.writeFile(importFile, importContent, "utf-8");
      configureArgs.push(
        "-DHERMES_ENABLE_TOOLS=OFF",
        "-DHERMES_ENABLE_TEST_SUITE=OFF",
        `-DIMPORT_HOST_COMPILERS=${importFile}`,
      );
    }
  }

  const cmake1 = Bun.spawn(["cmake", ...configureArgs], {
    cwd: bareDir, stdout: "inherit", stderr: "inherit",
  });
  if (await cmake1.exited !== 0) throw new Error("[zapp] Bare cmake configure failed");

  // Build BOTH bare_static (libbare.a — the runtime we link against)
  // and bare_bin (the CLI executable). We don't ship bare_bin, but
  // building it forces the bare-* module bindings declared in
  // vendor/bare/bin/CMakeLists.txt's `link_bare_module()` calls
  // (bare-crypto, bare-dns, bare-tcp, bare-tls, bare-pipe,
  // bare-inspector, bare-repl, bare-signals, bare-tty) to compile.
  // Without this, the `binding.c.o` files don't exist and
  // `ensureBareModulesArchive` can't pick them up — so user worker
  // code that does `import "bare-fetch"` (which transitively needs
  // bare-tcp/tls/dns) blows up at runtime with
  // `No addon registered for 'bare_tcp'`.
  //
  // The cost is a slightly slower build (compile the bare CLI's main
  // and link it) but `bare_bin` is discarded — nothing in our binary
  // references it. The .a we ship is unchanged in size; only
  // libbare_modules.a grows to include the extra bindings.
  // See the short-circuit branch above for why iOS targets fall back
  // to `bare_static`. `bare_bin` is a macOS-only convenience to force
  // bare-* module bindings to compile.
  //
  // Windows also uses `bare_static`: the bare.exe link fails under
  // MinGW (exports.def wants js_*_garbage_collection_tracking symbols
  // the QuickJS backend doesn't define, and BoringSSL's fiat adx asm
  // doesn't land in libcrypto.a) — and we never ship the exe anyway.
  // bare-* bindings surface via the user-modules overlay path
  // (`ensureUserBareModulesCompiled`), same as iOS.
  const bareTarget = isIOSTarget(target) || target === "windows" ? "bare_static" : "bare_bin";

  // For the Hermes engine we need to patch bare's embedded
  // `bare.js.h` after it's generated but before `bare.c.o` is
  // compiled. The bundle contains class shapes that crash Hermes'
  // AST transformer (see downlevel-bare-js.ts comment block). Split
  // the build: 1) build just `bare_bundle` to produce the .h, 2)
  // rewrite the .h via the downleveler, 3) build the rest — cmake
  // sees the .h is newer and rebuilds `bare.c.o` against the
  // lowered bundle.
  //
  // For non-Hermes engines we do the original single-pass build,
  // so JSC / V8 / QuickJS / mQJS pay nothing for this.
  if (engine === "hermes") {
    const bundleBuild = Bun.spawn(
      ["cmake", "--build", buildDir, "--target", "bare_bundle", "-j4"],
      { cwd: bareDir, stdout: "inherit", stderr: "inherit" },
    );
    if (await bundleBuild.exited !== 0) {
      throw new Error("[zapp] Bare cmake bare_bundle build failed");
    }
    const { downlevelBareJsForHermes } = await import("./downlevel-bare-js.js");
    await downlevelBareJsForHermes(bareDir);
  }

  const cmake2 = Bun.spawn(["cmake", "--build", buildDir, "--target", bareTarget, "-j4"], {
    cwd: bareDir, stdout: "inherit", stderr: "inherit",
  });
  if (await cmake2.exited !== 0) throw new Error("[zapp] Bare cmake build failed");
  pruneBareSharedLib(path.join(bareDir, buildDir));

  if (projectRoot) {
    await ensureUserBareModulesCompiled(bareDir, buildDir, projectRoot, target);
  }
  await ensureBareModulesArchive(path.join(bareDir, buildDir), projectRoot, target);

  clog(0, `Bare (${engine}) built successfully`);
  return bareDir;
}

// Compile bare-* modules from the user's `node_modules/` (e.g.
// `bare-zlib`) when vendor/bare's own deps don't include them.
//
// Approach: generate a small side cmake project at
// `<bareBuild>/zapp-user-modules/` that:
//   1. find_package(cmake-bare REQUIRED PATHS @vendor/bare/node_modules/cmake-bare)
//   2. declares a placeholder STATIC library `zapp_user_modules`
//   3. calls `link_bare_module(zapp_user_modules <name> WORKING_DIRECTORY <project>)`
//      for each user-only bare-* with a binding.c
//
// `link_bare_module` is cmake-bare's helper that `add_subdirectory()`s
// the module and links its `binding.c.o` into the receiver, with the
// right `BARE_MODULE_NAME="<name>@<version>"` / `BARE_MODULE_REGISTER_CONSTRUCTOR`
// compile defs. We don't actually USE the resulting static library —
// what we want is the `binding.c.o` it drops in
// `<user-build>/node_modules/<name>/CMakeFiles/<name>-<ver>-<hash>.dir/`,
// which `ensureBareModulesArchive` then sweeps up alongside vendor's
// own bindings.
//
// macOS `bare_bin` target transitively builds `bare_shared`, which
// produces `libbare.dylib` (and `.tbd`) next to `libbare.a`. Zapp's
// host link uses `-L<bareBuild> -lbare`, and the macOS linker prefers
// `.dylib` over `.a` — so the host binary ends up with an
// unsatisfiable `@rpath/libbare.dylib` LC_LOAD_DYLIB and crashes at
// launch (`dyld: Library not loaded: @rpath/libbare.dylib`). We
// don't ship the bare daemon or use libbare at runtime as a
// dynamic library, so the cleanest fix is to remove the shared
// artifacts after the build. iOS doesn't build `bare_bin` and
// therefore never emits these.
function pruneBareSharedLib(buildDir: string): void {
  for (const name of ["libbare.dylib", "libbare.tbd"]) {
    const p = path.join(buildDir, name);
    if (existsSync(p)) {
      try { unlinkSync(p); } catch {}
    }
  }
}

// No-op when the user has no bare-* with binding.c that's missing
// from vendor.
async function ensureUserBareModulesCompiled(
  bareDir: string,
  buildDir: string,
  projectRoot: string,
  target: BuildTarget,
): Promise<void> {
  const fs = await import("node:fs/promises");
  const userModulesDir = path.join(projectRoot, "node_modules");
  const vendorModulesDir = path.join(bareDir, "node_modules");

  // Collect user-installed bare-* with binding.c.
  let entries: string[] = [];
  try { entries = await fs.readdir(userModulesDir); }
  catch { entries = []; }
  const userBareWithBinding: string[] = [];
  for (const name of entries) {
    if (!name.startsWith("bare-")) continue;
    const bindingPath = path.join(userModulesDir, name, "binding.c");
    if (existsSync(bindingPath)) userBareWithBinding.push(name);
  }

  // Filter out the ones vendor/bare already compiled. On macOS that's
  // most of vendor's deps (via the bare_bin build); on iOS the
  // `bare_bin` target is gated off (MACOSX_BUNDLE conflict — see
  // vendor/bare/CMakeLists.txt patch), so we ALSO have to compile
  // vendor's bare-* bindings ourselves through the overlay.
  const onlyUserNeeded = userBareWithBinding.filter((name) => {
    return !existsSync(path.join(vendorModulesDir, name, "binding.c"));
  });

  // Vendor's own bare-* deps that need to land in libbare_modules.a
  // when bare_bin isn't being built — same set bare_bin uses (see
  // vendor/bare/bin/CMakeLists.txt:link_bare_module calls). Keep
  // this list narrow: only the ones with a runtime-side native
  // binding. Pure-JS bare-* don't need cmake build at all.
  const VENDOR_BARE_NATIVE_DEPS = [
    "bare-crypto",
    "bare-dns",
    "bare-inspector",
    "bare-pipe",
    "bare-signals",
    "bare-tcp",
    "bare-tls",
    "bare-tty",
  ];
  const vendorNeeded: string[] = [];
  if (isIOSTarget(target)) {
    for (const name of VENDOR_BARE_NATIVE_DEPS) {
      if (existsSync(path.join(vendorModulesDir, name, "binding.c"))) {
        vendorNeeded.push(name);
      }
    }
  }

  const linkSpecs: Array<{ name: string; workingDir: string }> = [
    ...onlyUserNeeded.map((name) => ({ name, workingDir: projectRoot })),
    ...vendorNeeded.map((name) => ({ name, workingDir: bareDir })),
  ];

  if (linkSpecs.length === 0) return;

  const summary = linkSpecs.map((s) => s.name).join(", ");
  clog(1, `compiling bare modules: ${summary}`);

  // Generate the overlay project.
  const overlayDir = path.join(bareDir, buildDir, "zapp-user-modules");
  const overlayBuildDir = path.join(overlayDir, "build");
  await fs.mkdir(overlayDir, { recursive: true });
  await fs.writeFile(path.join(overlayDir, "empty.c"), "// placeholder\n");

  // Symlink vendor/bare's `node_modules/` into the overlay so the
  // cmake-bare → cmake-npm → cmake-fetch chain (which uses relative
  // `find_package(X REQUIRED PATHS node_modules/X)` calls internally)
  // can resolve all its peers. Without this symlink, cmake-bare's
  // own dependency `find_package(cmake-npm REQUIRED PATHS
  // node_modules/cmake-npm)` looks under the overlay's
  // CMAKE_CURRENT_SOURCE_DIR (which has no node_modules) and fails
  // with "Could not find a package configuration file provided by
  // 'cmake-npm'".
  const overlayNodeModules = path.join(overlayDir, "node_modules");
  if (!existsSync(overlayNodeModules)) {
    // "junction" on Windows — real symlinks need Developer Mode or
    // admin (EPERM otherwise); junctions don't. Node ignores the type
    // argument on POSIX, so passing it unconditionally is safe.
    await fs.symlink(
      path.join(bareDir, "node_modules"),
      overlayNodeModules,
      process.platform === "win32" ? "junction" : "dir"
    );
  }

  const linkCalls = linkSpecs
    .map((s) =>
      // Forward slashes — cmake treats backslashes in quoted strings
      // as escapes ("C:\Users" → invalid escape '\U').
      `link_bare_module(zapp_user_modules ${s.name} WORKING_DIRECTORY "${s.workingDir.replace(/\\/g, "/")}")`
    )
    .join("\n");
  const cmakeLists = `cmake_minimum_required(VERSION 4.0)

# Mirrors vendor/bare/CMakeLists.txt's find_package set. All resolve
# through the symlinked node_modules/ above.
find_package(cmake-bare       REQUIRED PATHS node_modules/cmake-bare)
find_package(cmake-harden     REQUIRED PATHS node_modules/cmake-harden)
find_package(cmake-bare-bundle REQUIRED PATHS node_modules/cmake-bare-bundle)
find_package(cmake-drive      REQUIRED PATHS node_modules/cmake-drive)
find_package(cmake-fetch      REQUIRED PATHS node_modules/cmake-fetch)
find_package(cmake-napi       REQUIRED PATHS node_modules/cmake-napi)

# Disable MACOSX_BUNDLE for executable targets BEFORE any subproject
# declares them. CMake's iOS toolchain defaults CMAKE_MACOSX_BUNDLE
# to ON, which causes BoringSSL's \`bssl\` CLI (pulled in transitively
# by bare-tls/crypto) to fail cmake configure on iOS:
#   install TARGETS given no BUNDLE DESTINATION for MACOSX_BUNDLE
#   executable target "bssl"
# We don't install those CLIs — they're a build-time artifact only.
# Forcing the variable OFF here propagates to all add_executable()
# calls in this subproject tree.
set(CMAKE_MACOSX_BUNDLE OFF CACHE BOOL "" FORCE)

project(zapp_user_bare_modules C)

bare_target(_target)

# Placeholder lib — we only care about the per-module binding.c.o
# files that cmake-bare drops alongside it under
# build/node_modules/<bare-X>/CMakeFiles/.
add_library(zapp_user_modules STATIC empty.c)

${linkCalls}
`;
  await fs.writeFile(path.join(overlayDir, "CMakeLists.txt"), cmakeLists);

  // Configure + build using the same target/SDK as bare itself so
  // generated objects link cleanly against libbare.a.
  const configureArgs = [
    "-S", overlayDir,
    "-B", overlayBuildDir,
    "-DCMAKE_BUILD_TYPE=Release",
  ];
  if (target === "windows") {
    // Same toolchain pin as the main bare configure in ensureBareBuilt
    // — the overlay's objects must link into the MinGW app build, and
    // the default VS generator breaks both the ABI and the flat
    // single-config artifact layout swept by ensureBareModulesArchive.
    configureArgs.push(
      "-G", "Ninja",
      "-DCMAKE_C_COMPILER=gcc",
      "-DCMAKE_CXX_COMPILER=g++",
      "-DCMAKE_C_FLAGS=-Wno-error=incompatible-pointer-types",
      "-DOPENSSL_NO_ASM=1", // see matching flag in ensureBareBuilt
    );
  }
  if (isIOSTarget(target)) {
    const sdk = target === "ios-simulator" ? "iphonesimulator" : "iphoneos";
    const proc = Bun.spawn(["xcrun", "--sdk", sdk, "--show-sdk-path"], { stdout: "pipe" });
    const sdkPath = (await new Response(proc.stdout).text()).trim();
    if (await proc.exited !== 0 || !sdkPath) {
      throw new Error(`[zapp] failed to resolve ${sdk} SDK path via xcrun`);
    }
    configureArgs.push(
      "-DCMAKE_SYSTEM_NAME=iOS",
      "-DCMAKE_SYSTEM_PROCESSOR=arm64",
      `-DCMAKE_OSX_SYSROOT=${sdkPath}`,
      "-DCMAKE_OSX_ARCHITECTURES=arm64",
      "-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0",
    );
  }

  const cfg = Bun.spawn(["cmake", ...configureArgs], {
    stdout: "inherit", stderr: "inherit",
  });
  if (await cfg.exited !== 0) {
    throw new Error("[zapp] user-module overlay configure failed");
  }
  const build = Bun.spawn(
    ["cmake", "--build", overlayBuildDir, "--target", "zapp_user_modules", "-j4"],
    { stdout: "inherit", stderr: "inherit" }
  );
  if (await build.exited !== 0) {
    throw new Error("[zapp] user-module overlay build failed");
  }
}

// Combine all bare-* npm-module binding objects into a single
// `libbare_modules.a` next to libbare.a. Each module registers itself
// with the Bare runtime via a static-init constructor (built by the
// BARE_MODULE_REGISTER_CONSTRUCTOR macro); without these the Bare
// runtime crashes during setup on the first `require('bare-buffer')`.
//
// CMake leaves them as bare binding.c.o files in
// node_modules/<mod>/CMakeFiles/<mod>.dir/. We `ar -rcs` them into a
// single archive that build-config.ts then -force_loads at link time.
async function ensureBareModulesArchive(
  buildDir: string,
  projectRoot?: string,
  target?: BuildTarget,
): Promise<void> {
  const fs = await import("node:fs/promises");
  const archivePath = path.join(buildDir, "libbare_modules.a");
  const objects: string[] = [];

  // 0. Windows only: liblog (holepunchto) builds as a CMake OBJECT
  //    library that bare_bin normally absorbs — but Windows builds
  //    bare_static, leaving log_error/log_warn/... undefined for the
  //    binding.c objects below. Sweep its objects into this archive.
  //    NOT on macOS: libbare.a defines log_* there, and force_load of
  //    a duplicate copy would break that link.
  if (target === "windows") {
    const liblogDir = path.join(
      buildDir, "_deps", "github+holepunchto+liblog-build", "CMakeFiles", "log.dir", "src",
    );
    if (existsSync(liblogDir)) {
      const logObjs = await fs.readdir(liblogDir);
      for (const o of logObjs) {
        if (o.endsWith(".o") || o.endsWith(".obj")) {
          objects.push(path.join(liblogDir, o));
        }
      }
    }
  }

  // 1. bare-* npm module bindings (binding.c.o) — each registers itself
  //    via static-init so they must be force-loaded at the final link.
  const nodeModulesDir = path.join(buildDir, "node_modules");
  if (existsSync(nodeModulesDir)) {
    const modules = await fs.readdir(nodeModulesDir);
    for (const mod of modules) {
      const cmakeFiles = path.join(nodeModulesDir, mod, "CMakeFiles");
      if (!existsSync(cmakeFiles)) continue;
      const dirs = await fs.readdir(cmakeFiles);
      for (const d of dirs) {
        if (d.endsWith("_module.dir")) continue;
        // CMake names objects binding.c.o on Unix and binding.c.obj on
        // Windows (even under MinGW gcc).
        for (const objName of ["binding.c.o", "binding.c.obj"]) {
          const candidate = path.join(cmakeFiles, d, objName);
          if (existsSync(candidate)) objects.push(candidate);
        }
      }
    }
  }

  // 1b. User-installed bare-* modules built via the overlay project
  //     (see `ensureUserBareModulesCompiled`). Same shape as the
  //     vendor scan above, just rooted at the overlay's build dir.
  const overlayBuild = path.join(buildDir, "zapp-user-modules", "build", "node_modules");
  if (existsSync(overlayBuild)) {
    const modules = await fs.readdir(overlayBuild);
    for (const mod of modules) {
      const cmakeFiles = path.join(overlayBuild, mod, "CMakeFiles");
      if (!existsSync(cmakeFiles)) continue;
      const dirs = await fs.readdir(cmakeFiles);
      for (const d of dirs) {
        if (d.endsWith("_module.dir")) continue;
        for (const objName of ["binding.c.o", "binding.c.obj"]) {
          const candidate = path.join(cmakeFiles, d, objName);
          if (existsSync(candidate)) objects.push(candidate);
        }
      }
    }
    // The overlay also fetches per-module C deps (e.g. madler/zlib for
    // bare-zlib). Pick up any leaf .c.o under the overlay's _deps too.
    const overlayDeps = path.join(buildDir, "zapp-user-modules", "build", "_deps");
    if (existsSync(overlayDeps)) {
      const deps = await fs.readdir(overlayDeps);
      for (const dep of deps) {
        if (!dep.endsWith("-build")) continue;
        if (/libjs-build|libjsc-build|libqjs-build|libmqjs-build|libuv-build|libutf-build|libnapi-build|libintrusive-build|librlimit-build|boringssl-build|c-ares-build/.test(dep)) continue;
        const cmakeFiles = path.join(overlayDeps, dep, "CMakeFiles");
        if (!existsSync(cmakeFiles)) continue;
        const dirs = await fs.readdir(cmakeFiles);
        for (const d of dirs) {
          if (d.includes("_shared.dir") || d.includes("_static.dir") ||
              d.includes("_test") || d.startsWith("test_")) continue;
          if (!d.endsWith(".dir")) continue;
          const collect = async (sub: string) => {
            const entries = await fs.readdir(sub, { withFileTypes: true });
            for (const e of entries) {
              const full = path.join(sub, e.name);
              if (e.isDirectory()) await collect(full);
              else if (e.name.endsWith(".c.o")) objects.push(full);
            }
          };
          await collect(path.join(cmakeFiles, d));
        }
      }
    }
  }
  // Avoid unused-parameter complaints when overlay is absent.
  void projectRoot;

  // 2. Holepunch support libs (libbase64, liblog, libhex, liburl) —
  //    referenced by the bare-* bindings but built as OBJECT-only
  //    targets, so cmake doesn't emit .a files for them. We pick up
  //    their .o files directly. (libnapi is already bundled into
  //    libbare.a via TARGET_OBJECTS in the bare CMakeLists.)
  const depsDir = path.join(buildDir, "_deps");
  if (existsSync(depsDir)) {
    const deps = await fs.readdir(depsDir);
    for (const dep of deps) {
      if (!dep.endsWith("-build")) continue;
      // Skip libs already linked separately or known not to need bundling.
      if (/libjs-build|libjsc-build|libqjs-build|libmqjs-build|libuv-build|libutf-build|libnapi-build|libintrusive-build|librlimit-build|boringssl-build|c-ares-build/.test(dep)) continue;
      const cmakeFiles = path.join(depsDir, dep, "CMakeFiles");
      if (!existsSync(cmakeFiles)) continue;
      const dirs = await fs.readdir(cmakeFiles);
      for (const d of dirs) {
        // Pick the non-shared, non-static, non-test target dir
        // (cmake-bare convention: <name>.dir for OBJECT, plus
        // <name>_static.dir / <name>_shared.dir).
        if (d.includes("_shared.dir") || d.includes("_static.dir") ||
            d.includes("_test") || d.startsWith("test_")) continue;
        if (!d.endsWith(".dir")) continue;
        const targetDir = path.join(cmakeFiles, d);
        // Walk the .dir for any .c.o file.
        const collect = async (sub: string) => {
          const entries = await fs.readdir(sub, { withFileTypes: true });
          for (const e of entries) {
            const full = path.join(sub, e.name);
            if (e.isDirectory()) await collect(full);
            else if (e.name.endsWith(".c.o")) objects.push(full);
          }
        };
        await collect(targetDir);
      }
    }
  }

  if (objects.length === 0) return;

  if (existsSync(archivePath)) await fs.unlink(archivePath);
  const ar = Bun.spawn(["ar", "-rcs", archivePath, ...objects], {
    cwd: buildDir, stdout: "inherit", stderr: "pipe",
  });
  if (await ar.exited !== 0) {
    throw new Error("[zapp] failed to build libbare_modules.a");
  }
}

// Return the set of Bare engines the user's build.zc opted into.
// Each ZAPP_WORKER_ENGINE_BARE_<NAME> directive enables one engine;
// multiple may be enabled in the same project (one worker uses JSC,
// another uses V8 — the runtime dispatcher routes per-worker).
export async function bareEnginesEnabled(
  root: string,
  overlayFile?: string,
  target: BuildTarget = detectTarget(),
  iosBuildFile?: string,
): Promise<BareEngine[]> {
  // On iOS, `_zapp_build_ios.zc` (generated by `generateIOSBuildFile`)
  // is the source of truth: it strips macos:-prefixed lines from the
  // user's build.zc and substitutes the iOS-appropriate engine choice
  // (bare-jsc by default). Prefer it over build.zc when present.
  const sources: string[] = [];
  if (iosBuildFile && isIOSTarget(target)) {
    sources.push(iosBuildFile);
  } else {
    sources.push(path.join(root, "zapp", "build.zc"));
  }
  if (overlayFile) sources.push(overlayFile);
  let combined = "";
  for (const f of sources) {
    try { combined += await Bun.file(f).text() + "\n"; } catch {}
  }
  if (!combined) return [];

  // Filter to lines applicable to the current target. zc's `//> macos:`
  // / `//> ios:` / `//> windows:` prefixes scope a directive to a host
  // (or build) platform — `bareEnginesEnabled` previously ignored the
  // prefix and counted any define regardless of scope, which meant
  // running `bun run dev --platform ios` with `//> macos: define:
  // ZAPP_WORKER_ENGINE_BARE_V8` triggered an iOS V8 build (V8 doesn't
  // work on iOS — needs JIT). Filter explicitly: keep lines with no
  // platform prefix, plus lines whose prefix matches the active
  // target's family (macos / ios / windows).
  const targetTag =
    target === "macos" ? "macos" :
    isIOSTarget(target) ? "ios" :
    target === "windows" ? "windows" : "";
  const lines = combined.split("\n").filter((raw) => {
    const m = raw.match(/^\s*\/\/>\s*([a-z-]+)\s*:/);
    if (!m) return true;
    const tag = m[1];
    if (tag === "define" || tag === "link" || tag === "cflags" ||
        tag === "lib" || tag === "framework" || tag === "include") {
      return true; // these are directive types, not platform prefixes
    }
    return tag === targetTag;
  });
  const filtered = lines.join("\n");

  const enabled: BareEngine[] = [];
  if (/^\/\/>.*define:.*ZAPP_WORKER_ENGINE_BARE_V8/m.test(filtered)) enabled.push("v8");
  if (/^\/\/>.*define:.*ZAPP_WORKER_ENGINE_BARE_JSC/m.test(filtered)) enabled.push("jsc");
  if (/^\/\/>.*define:.*ZAPP_WORKER_ENGINE_BARE_QUICKJS/m.test(filtered)) enabled.push("quickjs");
  if (/^\/\/>.*define:.*ZAPP_WORKER_ENGINE_BARE_MQJS/m.test(filtered)) enabled.push("mqjs");
  if (/^\/\/>.*define:.*ZAPP_WORKER_ENGINE_BARE_HERMES/m.test(filtered)) enabled.push("hermes");
  return enabled;
}

/** True when at least one Bare engine variant is enabled. */
export async function hasBareEnabled(root: string): Promise<boolean> {
  return (await bareEnginesEnabled(root)).length > 0;
}

/** Engine identifier returned by `hasAnyWorkerEngine`. */
export type WorkerEngine =
  | "bare-v8"
  | "bare-jsc"
  | "bare-quickjs"
  | "bare-mqjs"
  | "bare-hermes"
  | "zjs";          // first-party: popaprozac/zjs, direct value bridge

// Check if any worker engine is defined. Returns the first engine that
// matches when multiple are enabled (build.zc allows several
// ZAPP_WORKER_ENGINE_* directives — the dispatcher in worker.zc routes
// per-worker at runtime, so this return value is informational only).
//
// Both call sites (zapp-cli.ts:154, :460) treat the return value as a
// truthy/null check; they never read which specific engine came back.
// The order below matches the documented fallback chain in
// cli/src/config.ts:HeadlessWorkerConfig:
// `zjs > bare-jsc > bare-v8 > bare-hermes > bare-quickjs > bare-mqjs`.
export async function hasAnyWorkerEngine(root: string): Promise<WorkerEngine | null> {
  const buildFile = path.join(root, "zapp", "build.zc");
  try {
    const content = await Bun.file(buildFile).text();
    if (/^\/\/>.*define:.*ZAPP_WORKER_ENGINE_ZJS\b/m.test(content)) return "zjs";
    if (/^\/\/>.*define:.*ZAPP_WORKER_ENGINE_BARE_JSC/m.test(content)) return "bare-jsc";
    if (/^\/\/>.*define:.*ZAPP_WORKER_ENGINE_BARE_V8/m.test(content)) return "bare-v8";
    if (/^\/\/>.*define:.*ZAPP_WORKER_ENGINE_BARE_HERMES/m.test(content)) return "bare-hermes";
    if (/^\/\/>.*define:.*ZAPP_WORKER_ENGINE_BARE_QUICKJS/m.test(content)) return "bare-quickjs";
    if (/^\/\/>.*define:.*ZAPP_WORKER_ENGINE_BARE_MQJS/m.test(content)) return "bare-mqjs";
    return null;
  } catch { return null; }
}

// True when this project links the bare-jsc engine. On Apple Silicon,
// JSC's tiered JIT is gated by the `com.apple.security.cs.allow-jit`
// entitlement — without it JSC stays in LLInt interpreter mode, ~12×
// slower on JIT-friendly workloads. `cli/src/entitlements.ts` consults
// this and auto-merges the entitlement so users don't have to configure
// it by hand to get JSC's speed claim.
export async function hasJscClassWorkerEngine(root: string): Promise<boolean> {
  const buildFile = path.join(root, "zapp", "build.zc");
  try {
    const content = await Bun.file(buildFile).text();
    return /^\/\/>.*define:.*ZAPP_WORKER_ENGINE_BARE_JSC/m.test(content);
  } catch { return false; }
}

interface CompileOptions {
  root: string;
  buildFile: string;         // User's zapp/build.zc
  buildConfigFile: string;   // .zapp/zapp_build_config.zc
  bootstrapFile?: string;    // .zapp/zapp_bootstrap.zc
  assetsFile?: string;       // .zapp/zapp_assets.zc (embedded brotli assets)
  headlessFile?: string;     // .zapp/zapp_headless_workers.zc
  engineOverlayFile?: string;// .zapp/zapp_engine_overlay.zc — auto-engine defines
  output: string;            // Binary output path
  nativeDir: string;         // Framework source dir
  optimize: boolean;         // Size optimizations
  target?: BuildTarget;      // Build target (default: host platform)
  /**
   * Resolved zapp.config.ts. Threaded into the platform-overlay
   * generator so user-declared `nativeSources` / `extraFrameworks`
   * / `extraLinkFlags` land in `.zapp/zapp_platform.zc` and the
   * deferred regen path (re-running platform-overlay generation from
   * inside compileNative) sees them too.
   */
  config?: import("./config").ResolvedConfig;
}

export async function compileNative(opts: CompileOptions): Promise<void> {
  const { root, buildFile, buildConfigFile, bootstrapFile, assetsFile, headlessFile, engineOverlayFile, output, nativeDir, optimize } = opts;
  const target: BuildTarget = opts.target ?? detectTarget();

  // Generate platform config with .m file paths. Forward the
  // caller's buildFile + engineOverlayFile so the platform config's
  // engine detection sees the same iOS-specific overlay
  // (`_zapp_build_ios.zc`) the rest of the pipeline uses — otherwise
  // it falls back to the raw `build.zc` whose `//> macos:` directives
  // don't apply to the iOS target, producing wrong -L/-l flags.
  const { generatePlatformConfig } = await import("./build-config");
  const platformFile = await generatePlatformConfig(
    root, target, buildFile, engineOverlayFile, opts.config,
  );

  const verbose = process.argv.includes("--verbose") || process.argv.includes("-v");

  const zcArgs = [
    "build",
    buildFile,
    buildConfigFile,
    platformFile,
    ...(bootstrapFile ? [bootstrapFile] : []),
    ...(assetsFile ? [assetsFile] : []),
    ...(headlessFile ? [headlessFile] : []),
    ...(engineOverlayFile ? [engineOverlayFile] : []),
    "-I", nativeDir,
    // The user's `zapp/` source dir on the include path so bare imports
    // in the build manifest (`import "app.zc";`) resolve to the user's
    // sources regardless of where the manifest itself lives. On iOS the
    // manifest is the generated `.zapp/_zapp_build_ios.zc`, so relative
    // resolution against the manifest's own dir would miss `zapp/app.zc`.
    "-I", path.join(root, "zapp"),
    "-o", output,
    // Apple targets (macOS + iOS) need --objective-c so the generated
    // .c file is parsed as ObjC (raw blocks contain NSLog, NSString*,
    // @"..." literals). Older zc versions (≤0.4.3) auto-enabled this
    // when building on macOS hosts; newer zc requires the explicit
    // flag, so we pass it on every Apple target regardless of host.
    ...(target === "macos" || isIOSTarget(target) ? ["--objective-c"] : []),
    // Suppress C compiler warnings by default. The framework and zc stdlib
    // generate ~200 warnings (parentheses-equality, incompatible-pointer-types,
    // etc.) that are pure noise for end users and bury any actual error.
    // Pass --verbose to see them.
    ...(verbose ? [] : ["-w"]),
  ];

  // Verbose: stream stdout AND stderr live so the user sees the whole
  // compile as it happens. Default: capture both, filter stderr for actual
  // errors only (zc + clang emit ~200 warnings from framework/stdlib that
  // are pure noise).
  const proc = Bun.spawn(["zc", ...zcArgs], {
    cwd: root,
    stdout: verbose ? "inherit" : "pipe",
    stderr: verbose ? "inherit" : "pipe",
  });

  const stdoutText = verbose ? "" : await new Response(proc.stdout).text();
  const stderrText = verbose ? "" : await new Response(proc.stderr).text();

  const exitCode = await proc.exited;
  if (exitCode !== 0) {
    const debug = process.argv.includes("--debug");
    if (debug) {
      // Full output (warnings, notes, the whole invocation).
      process.stderr.write(stderrText);
    } else if (stderrText) {
      // Default: print error/linker lines + their context, but NEVER swallow —
      // if the filter matches nothing, dump the whole stderr (the old code threw
      // it all away, which hid linker "Undefined symbols" / ld: blocks).
      const lines = stderrText.split("\n");
      const kept: string[] = [];
      for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        if (line.includes("error:") || line.includes("error :") ||
            line.includes("Undefined symbols") || line.startsWith("ld:") ||
            line.includes("symbol(s) not found")) {
          kept.push(line);
          for (let j = 1; j <= 4 && i + j < lines.length; j++) {
            const next = lines[i + j];
            if (next.startsWith(" ") || next.startsWith("|") || next.match(/^\s*\d+\s*\|/)) {
              kept.push(next);
            } else break;
          }
        }
      }
      process.stderr.write(kept.length > 0 ? kept.join("\n") + "\n" : stderrText);
    }
    throw new Error(
      `[zapp] native build failed (exit ${exitCode})` +
      (debug ? "" : " — run with --debug for the full compiler invocation")
    );
  }

  // Strip deferred for v2 baseline
}
