// Native compilation — compiles with zc.

import path from "node:path";
import { existsSync } from "node:fs";
import { readdir } from "node:fs/promises";
import { resolveTxikiDir } from "./paths";

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
      path.join(darwinDir, "fs.m"),
      path.join(darwinDir, "clipboard.m"),
      path.join(darwinDir, "shortcuts.m"),
    ];
    const jscWorker = path.join(nativeDir, "worker", "engines", "jsc.m");
    if (existsSync(jscWorker)) sources.push(jscWorker);
    return sources.filter(f => existsSync(f));
  }
  if (isIOSTarget(target)) {
    const iosDir = path.join(nativeDir, "platform", "ios");
    // Mirrors the darwin/ source list — every file here is the iOS
    // counterpart of the same-named darwin/ file. Symbols match
    // (darwin_window_create, darwin_clipboard_read_text, etc.) so
    // the Zen-C framework calls bind unchanged across platforms.
    const sources = [
      path.join(iosDir, "platform.m"),
      path.join(iosDir, "window.m"),
      path.join(iosDir, "webview.m"),
      path.join(iosDir, "dialog.m"),
      path.join(iosDir, "menu.m"),
      path.join(iosDir, "notification.m"),
      path.join(iosDir, "sync.m"),
      path.join(iosDir, "dock.m"),
      path.join(iosDir, "fs.m"),
      path.join(iosDir, "clipboard.m"),
      path.join(iosDir, "shortcuts.m"),
    ];
    // JSC worker engine — same file works on iOS (no JIT but same API)
    const jscWorker = path.join(nativeDir, "worker", "engines", "jsc.m");
    if (existsSync(jscWorker)) sources.push(jscWorker);
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
      } else if (entry.isFile() && entry.name.endsWith(ext)) {
        results.push(full);
      }
    }
  }
  await walk(projectZapp);
  return results;
}

// Ensure txiki.js is available and built (cmake).
// Downloads on-demand if not found in monorepo or cache.
export async function ensureTxikiBuilt(_nativeDir: string): Promise<string> {
  const txikiDir = await resolveTxikiDir();
  const libPath = path.join(txikiDir, "build", "libtjs_core.a");

  if (existsSync(libPath)) return txikiDir; // already built

  process.stdout.write("[zapp] building txiki.js (first time only, may take a minute)...\n");

  const cmake1 = Bun.spawn(["cmake", "-B", "build", "-DCMAKE_BUILD_TYPE=Release"], {
    cwd: txikiDir, stdout: "inherit", stderr: "inherit",
  });
  if (await cmake1.exited !== 0) throw new Error("[zapp] txiki.js cmake configure failed");

  const cmake2 = Bun.spawn(["cmake", "--build", "build", "-j4"], {
    cwd: txikiDir, stdout: "inherit", stderr: "inherit",
  });
  if (await cmake2.exited !== 0) throw new Error("[zapp] txiki.js cmake build failed");

  process.stdout.write("[zapp] txiki.js built successfully\n");
  return txikiDir;
}

// Check if user's build.zc enables txiki
export async function hasTxikiEnabled(root: string): Promise<boolean> {
  const buildFile = path.join(root, "zapp", "build.zc");
  try {
    const content = await Bun.file(buildFile).text();
    return /^\/\/>.*define:.*ZAPP_WORKER_ENGINE_TXIKI/m.test(content);
  } catch { return false; }
}

// Check if any worker engine is defined
export async function hasAnyWorkerEngine(root: string): Promise<"jsc" | "txiki" | null> {
  const buildFile = path.join(root, "zapp", "build.zc");
  try {
    const content = await Bun.file(buildFile).text();
    if (/^\/\/>.*define:.*ZAPP_WORKER_ENGINE_TXIKI/m.test(content)) return "txiki";
    if (/^\/\/>.*define:.*ZAPP_WORKER_ENGINE_JSC/m.test(content)) return "jsc";
    return null;
  } catch { return null; }
}

interface CompileOptions {
  root: string;
  buildFile: string;         // User's zapp/build.zc
  buildConfigFile: string;   // .zapp/zapp_build_config.zc
  bootstrapFile?: string;    // .zapp/zapp_bootstrap.zc
  assetsFile?: string;       // .zapp/zapp_assets.zc (embedded brotli assets)
  headlessFile?: string;     // .zapp/zapp_headless_workers.zc
  output: string;            // Binary output path
  nativeDir: string;         // Framework source dir
  optimize: boolean;         // Size optimizations
  target?: BuildTarget;      // Build target (default: host platform)
}

export async function compileNative(opts: CompileOptions): Promise<void> {
  const { root, buildFile, buildConfigFile, bootstrapFile, assetsFile, headlessFile, output, nativeDir, optimize } = opts;
  const target: BuildTarget = opts.target ?? detectTarget();

  // Generate platform config with .m file paths
  const { generatePlatformConfig } = await import("./build-config");
  const platformFile = await generatePlatformConfig(root, target);

  const verbose = process.argv.includes("--verbose") || process.argv.includes("-v");

  const zcArgs = [
    "build",
    buildFile,
    buildConfigFile,
    platformFile,
    ...(bootstrapFile ? [bootstrapFile] : []),
    ...(assetsFile ? [assetsFile] : []),
    ...(headlessFile ? [headlessFile] : []),
    "-I", nativeDir,
    "-o", output,
    // iOS targets need --objective-c so the generated .c file is parsed
    // as ObjC (raw blocks contain NSLog, NSString*, @"..." literals
    // gated by #ifdef __APPLE__). On macOS hosts zc auto-enables this
    // for darwin builds; for cross-target iOS we have to ask for it
    // explicitly.
    ...(isIOSTarget(target) ? ["--objective-c"] : []),
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
    if (!verbose && stderrText) {
      // Filter out warning/note lines; keep error lines + surrounding context.
      const lines = stderrText.split("\n");
      const errorLines: string[] = [];
      for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        if (line.includes("error:") || line.includes("error :")) {
          // Include a bit of context (the error line itself and up to 3 following indented/source lines).
          errorLines.push(line);
          for (let j = 1; j <= 4 && i + j < lines.length; j++) {
            const next = lines[i + j];
            if (next.startsWith(" ") || next.startsWith("|") || next.match(/^\s*\d+\s*\|/)) {
              errorLines.push(next);
            } else {
              break;
            }
          }
        }
      }
      if (errorLines.length > 0) {
        process.stderr.write(errorLines.join("\n") + "\n");
      } else {
        // Couldn't find anything that looks like an error — dump the full stderr
        // so users aren't left staring at just "compilation failed".
        process.stderr.write(stderrText);
      }
    }
    throw new Error(`[zapp] compilation failed (exit ${exitCode}). Run with --verbose for full output.`);
  }

  // Strip deferred for v2 baseline
}
