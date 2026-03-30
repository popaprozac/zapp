// Native compilation — resolves framework source, compiles with zc.

import path from "node:path";
import { existsSync } from "node:fs";

// Resolve the v2/native framework directory.
// Monorepo: ../../native relative to CLI
// Published: ./native bundled with CLI package
export function resolveNativeDir(): string {
  const cliDir = import.meta.dir;

  // Monorepo: v2/cli/src/ → v2/native/
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
