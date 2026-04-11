// Native compilation — resolves framework source, compiles with zc.

import path from "node:path";
import { existsSync } from "node:fs";

// Resolve the native framework directory.
// Monorepo: ../../native relative to CLI
// Published: ./native bundled with CLI package
export function resolveNativeDir(): string {
  const cliDir = import.meta.dir;

  // Monorepo: cli/src/ → native/
  const monorepo = path.resolve(cliDir, "../../native");
  if (existsSync(path.join(monorepo, "app", "app.zc"))) {
    return monorepo;
  }

  // Published: cli/native/
  const bundled = path.resolve(cliDir, "../native");
  if (existsSync(path.join(bundled, "app", "app.zc"))) {
    return bundled;
  }

  throw new Error(
    "[zapp] Cannot find v2 native framework. Expected:\n" +
    `  - ${monorepo}/app/app.zc  (monorepo)\n` +
    `  - ${bundled}/app/app.zc  (published)\n`
  );
}

// Get platform-specific .m files to compile alongside the generated .c
export function getPlatformSources(nativeDir: string): string[] {
  if (process.platform === "darwin") {
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
    ];
    // JSC worker engine (always safe — system framework)
    const jscWorker = path.join(nativeDir, "worker", "engines", "jsc.m");
    if (existsSync(jscWorker)) sources.push(jscWorker);
    // txiki.c NOT auto-included — requires txiki.js libs
    // Users add it via workers-txiki.zc or build.zc defines + cflags
    return sources.filter(f => existsSync(f));
  }
  if (process.platform === "win32") {
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

// Ensure txiki.js is built (cmake). Only runs if libtjs_core.a doesn't exist.
export async function ensureTxikiBuilt(nativeDir: string): Promise<void> {
  const txikiDir = path.resolve(nativeDir, "../vendor/txiki.js");
  const libPath = path.join(txikiDir, "build", "libtjs_core.a");

  if (!existsSync(path.join(txikiDir, "src", "tjs.h"))) {
    throw new Error("[zapp] txiki.js not found in vendor/txiki.js. Run: git submodule update --init");
  }

  if (existsSync(libPath)) return; // already built

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
  output: string;            // Binary output path
  nativeDir: string;         // Framework source dir
  optimize: boolean;         // Size optimizations
}

export async function compileNative(opts: CompileOptions): Promise<void> {
  const { root, buildFile, buildConfigFile, bootstrapFile, assetsFile, output, nativeDir, optimize } = opts;

  // Generate platform config with .m file paths
  const { generatePlatformConfig } = await import("./build-config");
  const platformFile = await generatePlatformConfig(root);

  const zcArgs = [
    "build",
    buildFile,
    buildConfigFile,
    platformFile,
    ...(bootstrapFile ? [bootstrapFile] : []),
    ...(assetsFile ? [assetsFile] : []),
    "-I", nativeDir,
    "-o", output,
  ];

  // Size optimizations deferred for v2 baseline.
  // When re-introduced: -Oz, -flto, --no-debug, strip

  // Debug: uncomment to see zc invocation
  // process.stderr.write(`[zapp] zc ${zcArgs.join(" ")}\n`);
  const proc = Bun.spawn(["zc", ...zcArgs], {
    cwd: root,
    stdout: "inherit",
    stderr: "inherit",
  });
  const exitCode = await proc.exited;
  if (exitCode !== 0) {
    throw new Error(`[zapp] zc compilation failed (exit ${exitCode})`);
  }

  // Strip deferred for v2 baseline
}
