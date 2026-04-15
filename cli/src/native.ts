// Native compilation — compiles with zc.

import path from "node:path";
import { existsSync } from "node:fs";
import { resolveTxikiDir } from "./paths";

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
}

export async function compileNative(opts: CompileOptions): Promise<void> {
  const { root, buildFile, buildConfigFile, bootstrapFile, assetsFile, headlessFile, output, nativeDir, optimize } = opts;

  // Generate platform config with .m file paths
  const { generatePlatformConfig } = await import("./build-config");
  const platformFile = await generatePlatformConfig(root);

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
