#!/usr/bin/env bun
import path from "node:path";
import process from "node:process";
import { mkdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import { loadConfig } from "./config";
import { generateBuildConfig, generatePlatformConfig } from "./build-config";
import { generateBindings } from "./generate";
import { resolveNativeDir, compileNative } from "./native";
import { runInit } from "./init";
import { bundleWorkers } from "./workers";
import { createDevBundle } from "./bundle";
import { createProductionBundle } from "./package";
import { generateBootstrap } from "../../bootstrap/codegen";
import { generateAssetManifest } from "./assets";

const cwd = process.cwd();

async function waitForPort(port: number, timeoutMs = 10000): Promise<boolean> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const res = await fetch(`http://localhost:${port}`, { signal: AbortSignal.timeout(500) });
      if (res.ok || res.status === 404) return true;
    } catch {}
    await new Promise(r => setTimeout(r, 200));
  }
  return false;
}

async function runDev(root: string) {
  if (process.platform !== "darwin" && process.platform !== "win32") {
    process.stderr.write("[zapp] dev mode is currently macOS and Windows only.\n");
    process.exit(1);
  }

  const config = await loadConfig(root);
  const nativeDir = resolveNativeDir();
  const port = config.devPort ?? 5173;
  const devUrl = `http://localhost:${port}`;

  // 1. Generate service bindings + bundle workers
  process.stdout.write("[zapp] scanning for services...\n");
  const count = await generateBindings(root);
  if (count > 0) process.stdout.write(`[zapp] generated ${count} binding(s) in src/zapp/\n`);
  const workerCount = await bundleWorkers(root);
  if (workerCount > 0) process.stdout.write(`[zapp] bundled ${workerCount} worker(s)\n`);

  // 2. Generate build config + bootstrap (dev mode)
  const buildConfigFile = await generateBuildConfig({ root, config, mode: "dev", devUrl });
  const platformFile = await generatePlatformConfig(root);
  const zappDir = path.join(root, ".zapp");
  process.stdout.write("[zapp] generating bootstrap...\n");
  const bootstrapFile = await generateBootstrap(zappDir);

  // 3. Start Vite dev server on a fixed port
  process.stdout.write("[zapp] starting vite dev server...\n");
  const viteProc = Bun.spawn(["bunx", "vite", "--port", String(port), "--strictPort"], {
    cwd: root,
    stdout: "inherit",
    stderr: "inherit",
  });

  // Wait for Vite to be ready
  const ready = await waitForPort(port);
  if (!ready) {
    process.stderr.write(`[zapp] vite dev server failed to start on port ${port}\n`);
    try { viteProc.kill(); } catch {}
    process.exit(1);
  }

  // 4. Compile native binary
  process.stdout.write("[zapp] compiling native binary...\n");
  const binDir = path.join(root, "bin");
  await mkdir(binDir, { recursive: true });
  const exeSuffix = process.platform === "win32" ? ".exe" : "";
  const nativeOut = path.join(binDir, config.name.replace(/\s+/g, "-").toLowerCase() + exeSuffix);

  const buildFile = path.join(root, "zapp", "build.zc");
  await compileNative({
    root,
    buildFile,
    buildConfigFile,
    bootstrapFile,
    output: nativeOut,
    nativeDir,
    optimize: false,
  });

  let execPath: string;

  if (process.platform === "darwin") {
    // 5. Create .app bundle for dev mode (enables notifications, dock icon, app name)
    process.stdout.write("[zapp] creating dev bundle...\n");
    const appDir = await createDevBundle(root, nativeOut, config);
    const execName = path.basename(nativeOut);
    execPath = path.join(appDir, "Contents", "MacOS", execName);
    process.stdout.write(`[zapp] launching ${appDir}\n`);
  } else {
    // Windows: self-contained WebView2 loader — no external DLL needed
    execPath = nativeOut;
    process.stdout.write(`[zapp] launching ${execPath}\n`);
  }

  const appProc = Bun.spawn([execPath], {
    cwd: root,
    stdout: "inherit",
    stderr: "inherit",
  });

  // Kill a process tree (Windows needs taskkill for child processes)
  const killProc = (proc: ReturnType<typeof Bun.spawn>) => {
    try {
      if (process.platform === "win32" && proc.pid) {
        Bun.spawnSync(["taskkill", "/F", "/T", "/PID", String(proc.pid)], {
          stdout: "ignore", stderr: "ignore",
        });
      } else {
        proc.kill();
      }
    } catch {}
  };

  // Handle Ctrl+C — terminate everything
  const cleanup = () => {
    killProc(appProc);
    killProc(viteProc);
    process.exit(0);
  };
  process.on("SIGINT", cleanup);
  process.on("SIGTERM", cleanup);

  // Wait for either to exit
  const exitCode = await Promise.race([
    appProc.exited,
    viteProc.exited,
  ]);

  // Cleanup — kill whichever is still running
  killProc(viteProc);
  killProc(appProc);
  process.exit(exitCode as number);
}

async function runBuild(root: string) {
  if (process.platform !== "darwin" && process.platform !== "win32") {
    process.stderr.write("[zapp] build is currently macOS and Windows only.\n");
    process.exit(1);
  }

  const config = await loadConfig(root);
  const nativeDir = resolveNativeDir();

  // 1. Generate service bindings + bundle workers
  process.stdout.write("[zapp] scanning for services...\n");
  const count = await generateBindings(root);
  if (count > 0) process.stdout.write(`[zapp] generated ${count} binding(s) in src/zapp/\n`);
  const workerCount = await bundleWorkers(root);
  if (workerCount > 0) process.stdout.write(`[zapp] bundled ${workerCount} worker(s)\n`);

  // 2. Build frontend with Vite
  process.stdout.write("[zapp] building frontend...\n");
  const viteProc = Bun.spawn(["bunx", "vite", "build"], {
    cwd: root,
    stdout: "inherit",
    stderr: "inherit",
  });
  const viteExit = await viteProc.exited;
  if (viteExit !== 0) {
    process.stderr.write("[zapp] vite build failed\n");
    process.exit(1);
  }

  // 3. Compress + embed assets with brotli
  process.stdout.write("[zapp] embedding assets with brotli...\n");
  const zappDir = path.join(root, ".zapp");
  const assetsFile = await generateAssetManifest(root, config.assetDir);

  // 4. Generate build config + bootstrap (prod mode, embedded assets)
  const buildConfigFile = await generateBuildConfig({ root, config, mode: "prod", embedAssets: true });
  const platformFile = await generatePlatformConfig(root);
  const bootstrapFile = await generateBootstrap(zappDir);

  // 5. Compile native binary (assets embedded in binary)
  process.stdout.write("[zapp] compiling native binary...\n");
  const binDir = path.join(root, "bin");
  await mkdir(binDir, { recursive: true });
  const buildExeSuffix = process.platform === "win32" ? ".exe" : "";
  const nativeOut = path.join(binDir, config.name.replace(/\s+/g, "-").toLowerCase() + buildExeSuffix);

  const buildFile = path.join(root, "zapp", "build.zc");
  await compileNative({
    root,
    buildFile,
    buildConfigFile,
    bootstrapFile,
    assetsFile,
    output: nativeOut,
    nativeDir,
    optimize: true,
  });

  const stat = Bun.file(nativeOut);
  const size = stat.size;
  process.stdout.write(`[zapp] build complete: ${nativeOut} (${Math.round(size / 1024)} KB)\n`);
}

async function runPackage(root: string) {
  if (process.platform !== "darwin") {
    process.stderr.write("[zapp] package is currently macOS-only.\n");
    process.exit(1);
  }

  // Run a full build first
  await runBuild(root);

  const config = await loadConfig(root);
  const binDir = path.join(root, "bin");
  const binaryPath = path.join(binDir, config.name.replace(/\s+/g, "-").toLowerCase());

  const sign = process.argv.includes("--sign") || process.argv.includes("--notarize");
  const notarize = process.argv.includes("--notarize");

  await createProductionBundle({
    root,
    binaryPath,
    config,
    sign,
    notarize,
  });
}

async function runGenerate(root: string) {
  const count = await generateBindings(root);
  process.stdout.write(`[zapp] generated ${count} binding(s) in src/zapp/\n`);
}

// --- CLI ---
const command = process.argv[2];
const root = path.resolve(cwd, process.argv.includes("-r")
  ? process.argv[process.argv.indexOf("-r") + 1] || "."
  : ".");

switch (command) {
  case "init": {
    const name = process.argv[3] || "zapp-app";
    const tIdx = process.argv.indexOf("-t");
    const templateIdx = process.argv.indexOf("--template");
    const template = tIdx >= 0 ? process.argv[tIdx + 1]
      : templateIdx >= 0 ? process.argv[templateIdx + 1]
      : "vanilla-ts";
    await runInit({ name, template, root: cwd });
    break;
  }
  case "dev":
    await runDev(root);
    break;
  case "build":
    await runBuild(root);
    break;
  case "generate":
    await runGenerate(root);
    break;
  case "package":
    await runPackage(root);
    break;
  default:
    console.log("Usage: zapp <init|dev|build|package|generate>");
    console.log("");
    console.log("  init [name] [-t template]  Scaffold a new project");
    console.log("  dev                        Development mode with Vite HMR");
    console.log("  build                      Production build");
    console.log("  package [--sign] [--notarize]  Create .app bundle for distribution");
    console.log("  generate                   Generate service bindings");
    process.exit(1);
}
