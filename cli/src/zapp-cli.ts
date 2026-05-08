#!/usr/bin/env bun
import path from "node:path";
import process from "node:process";
import { mkdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import { loadConfig } from "./config";
import { generateBuildConfig, generatePlatformConfig, generateHeadlessWorkers, generateIOSBuildFile } from "./build-config";
import { generateBindings } from "./generate";
import { compileNative, ensureTxikiBuilt, hasTxikiEnabled, hasAnyWorkerEngine, detectTarget, isIOSTarget, type BuildTarget } from "./native";
import { resolveNativeDir, resolveBootstrapDir } from "./paths";
import { runInit } from "./init";
// bundleWorkers removed — Vite plugin handles worker bundling now
import { createDevBundle } from "./bundle";
import { createProductionBundle } from "./package";
import { generateAssetManifest } from "./assets";

// Bootstrap codegen lives outside cli/ in the monorepo but is bundled
// alongside it in the published package. Dynamic import so the path
// can be resolved at runtime for both layouts.
const bootstrapDir = resolveBootstrapDir();
const { generateBootstrap } = await import(path.join(bootstrapDir, "codegen.ts"));

const cwd = process.cwd();

// Minimal Info.plist for iOS dev/spike builds. Enough for simctl
// install + launch to succeed; production packaging (Phase 3) replaces
// this with the full plist + icons + entitlements path.
async function writeIOSDevPlist(opts: {
  binaryPath: string;
  config: { name: string; identifier?: string; version?: string; ios?: { minimumSystemVersion?: string; deviceFamily?: string } };
  target: BuildTarget;
}): Promise<void> {
  const { binaryPath, config, target } = opts;
  const appBundle = path.dirname(binaryPath);
  const exeName = path.basename(binaryPath);
  const bundleId = config.identifier ?? `com.zapp.${config.name.replace(/\s+/g, "-").toLowerCase()}.dev`;
  const version = config.version ?? "0.1.0";
  const minVersion = config.ios?.minimumSystemVersion ?? "15.0";
  // UIDeviceFamily values: 1 = iPhone, 2 = iPad. Universal lists both.
  const family = config.ios?.deviceFamily ?? "universal";
  const deviceFamilyArray = family === "iphone" ? "<integer>1</integer>"
    : family === "ipad" ? "<integer>2</integer>"
    : "<integer>1</integer><integer>2</integer>";
  // DTPlatformName is what simctl uses to verify the bundle was built
  // for the right SDK. Without it, install fails with a confusing
  // "MissingBundleExecutable" or similar.
  const platformName = target === "ios-simulator" ? "iphonesimulator" : "iphoneos";

  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>${exeName}</string>
  <key>CFBundleIdentifier</key><string>${bundleId}</string>
  <key>CFBundleName</key><string>${config.name}</string>
  <key>CFBundleDisplayName</key><string>${config.name}</string>
  <key>CFBundleVersion</key><string>${version}</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleSupportedPlatforms</key><array><string>${platformName === "iphonesimulator" ? "iPhoneSimulator" : "iPhoneOS"}</string></array>
  <key>DTPlatformName</key><string>${platformName}</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>MinimumOSVersion</key><string>${minVersion}</string>
  <key>UIDeviceFamily</key><array>${deviceFamilyArray}</array>
  <key>UILaunchScreen</key><dict/>
  <key>UIRequiredDeviceCapabilities</key><array><string>arm64</string></array>
  <key>UISupportedInterfaceOrientations</key><array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
  </array>
</dict>
</plist>
`;
  await Bun.write(path.join(appBundle, "Info.plist"), plist);
}

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
    process.stderr.write("[zapp] dev mode is currently macOS, iOS, and Windows only.\n");
    process.exit(1);
  }

  const target: BuildTarget = detectTarget();
  if (isIOSTarget(target) && process.platform !== "darwin") {
    process.stderr.write("[zapp] iOS dev requires macOS host (Xcode SDK).\n");
    process.exit(1);
  }

  const config = await loadConfig(root);
  const nativeDir = resolveNativeDir();
  const port = config.devPort ?? 5173;
  // iOS Simulator on Apple Silicon shares host network namespace, so
  // localhost from inside the sim resolves to the same Vite dev server
  // the host is binding. No special tunnel needed.
  const devUrl = `http://localhost:${port}`;
  const isIOS = isIOSTarget(target);
  if (isIOS) {
    process.stdout.write(`[zapp] target: ${target}\n`);
  }

  // 0. Check worker engine
  const workerEngine = await hasAnyWorkerEngine(root);
  if (!workerEngine) {
    process.stderr.write(
      "[zapp] no worker engine defined in zapp/build.zc.\n" +
      "  Add one of:\n" +
      "    //> macos: define: ZAPP_WORKER_ENGINE_JSC    (zero binary cost, macOS-only)\n" +
      "    //> define: ZAPP_WORKER_ENGINE_TXIKI          (cross-platform, +6MB, web APIs)\n"
    );
    process.exit(1);
  }

  // 1. Generate service bindings + bundle workers
  process.stdout.write("[zapp] scanning for services...\n");
  const count = await generateBindings(root);
  if (count > 0) process.stdout.write(`[zapp] generated ${count} binding(s) in src/zapp/\n`);
  // Workers are bundled by the Vite plugin during vite build/dev

  // 2. Build txiki.js if opted in (per-target — iOS Sim cross-build
  // happens here on first run, takes ~1 min).
  if (workerEngine === "txiki") {
    await ensureTxikiBuilt(nativeDir, target);
  }

  // 3. Generate build config + bootstrap (dev mode)
  const buildConfigFile = await generateBuildConfig({ root, config, mode: "dev", devUrl });
  const platformFile = await generatePlatformConfig(root, target);
  const headlessFile = await generateHeadlessWorkers({ root, headless: config.headless });
  const zappDir = path.join(root, ".zapp");
  process.stdout.write("[zapp] generating bootstrap...\n");
  const bootstrapFile = await generateBootstrap(zappDir);

  // Generate stub assets file (no embedded assets in dev, but symbols must exist for linking)
  const stubAssets = `// Stub — no embedded assets in dev mode.\nraw {\n` +
    `    #include <compression.h>\n` +
    `    #ifndef ZAPP_EMBEDDED_ASSET_DEFINED\n` +
    `    #define ZAPP_EMBEDDED_ASSET_DEFINED\n` +
    `    typedef struct { const char* path; uint8_t* data; int len; int uncompressed_len; int is_brotli; } ZappEmbeddedAsset;\n` +
    `    #endif\n` +
    `    ZappEmbeddedAsset zapp_embedded_assets[1] = {{0}};\n` +
    `    int zapp_embedded_assets_count = 0;\n}\n`;
  const assetsFile = path.join(zappDir, "zapp_assets.zc");
  await Bun.write(assetsFile, stubAssets);

  // 3. Start Vite dev server on a fixed port
  // Detect a stale process holding the port — usually a Vite from a previous
  // crashed dev run. With --strictPort our new Vite would die immediately
  // and waitForPort would succeed against the *old* process, masking the failure.
  if (process.platform !== "win32") {
    const lsof = Bun.spawnSync(["lsof", "-ti", `:${port}`], { stdout: "pipe", stderr: "ignore" });
    const pids = lsof.stdout.toString().trim().split("\n").filter(Boolean);
    if (pids.length > 0) {
      process.stderr.write(
        `[zapp] port ${port} is already in use (pid ${pids.join(", ")}).\n` +
        `  Likely a stale Vite from a previous dev run. Run:\n` +
        `    kill ${pids.join(" ")}\n`
      );
      process.exit(1);
    }
  }

  process.stdout.write("[zapp] starting vite dev server...\n");
  const viteProc = Bun.spawn(["bunx", "vite", "--port", String(port), "--strictPort"], {
    cwd: root,
    stdout: "inherit",
    stderr: "inherit",
  });

  // Wait for Vite to be ready — but also fail fast if the spawned process dies
  // (e.g. plugin error during startup).
  const ready = await Promise.race([
    waitForPort(port),
    viteProc.exited.then(() => "vite-died" as const),
  ]);
  if (ready !== true) {
    process.stderr.write(`[zapp] vite dev server failed to start on port ${port}\n`);
    try { viteProc.kill(); } catch {}
    process.exit(1);
  }

  // Kill a process tree (Windows needs taskkill for child processes)
  const killProc = (proc: ReturnType<typeof Bun.spawn> | null) => {
    if (!proc) return;
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

  // Register cleanup NOW, before the compile step. If compilation throws
  // (zc error, missing dep, etc.), vite would otherwise leak — the next
  // `bun run dev` would then fail with "port 5173 already in use" and
  // force the user to manually `kill` the stale vite.
  let appProc: ReturnType<typeof Bun.spawn> | null = null;
  let cleaned = false;
  const cleanup = (code?: number) => {
    if (cleaned) return;
    cleaned = true;
    killProc(appProc);
    killProc(viteProc);
    if (code !== undefined) process.exit(code);
  };

  process.on("SIGINT", () => cleanup(0));
  process.on("SIGTERM", () => cleanup(0));
  process.on("exit", () => { cleaned = true; killProc(viteProc); killProc(appProc); });
  process.on("uncaughtException", (err) => {
    console.error("[zapp] uncaught exception:", err);
    cleanup(1);
  });
  process.on("unhandledRejection", (err) => {
    console.error("[zapp] unhandled rejection:", err);
    cleanup(1);
  });

  // 4. Compile native binary. If this throws, cleanup() above kills vite.
  process.stdout.write("[zapp] compiling native binary...\n");
  const binDir = path.join(root, "bin");
  await mkdir(binDir, { recursive: true });
  const exeName = config.name.replace(/\s+/g, "-").toLowerCase();
  const exeSuffix = process.platform === "win32" ? ".exe" : "";
  let nativeOut: string;
  if (isIOS) {
    const appBundle = path.join(binDir, "ios", `${config.name}.app`);
    await mkdir(appBundle, { recursive: true });
    nativeOut = path.join(appBundle, exeName);
  } else {
    nativeOut = path.join(binDir, exeName + exeSuffix);
  }

  const userBuildFile = path.join(root, "zapp", "build.zc");
  // iOS: swap user's build.zc for the CLI-generated overlay (strips
  // `//> macos:` directives that don't apply for the iOS target).
  const buildFile = isIOS
    ? await generateIOSBuildFile(root, userBuildFile)
    : userBuildFile;

  try {
    await compileNative({
      root,
      buildFile,
      buildConfigFile,
      bootstrapFile,
      assetsFile,
      headlessFile,
      output: nativeOut,
      nativeDir,
      optimize: false,
      target,
    });
  } catch (err) {
    killProc(viteProc);
    throw err;
  }

  let execPath: string;

  if (isIOS) {
    // iOS: write Info.plist into the bundle, ad-hoc sign, install +
    // launch on the booted sim. Same flow as runBuild's iOS path.
    await writeIOSDevPlist({ binaryPath: nativeOut, config, target });
    const appBundle = path.dirname(nativeOut);
    const signProc = Bun.spawn(["codesign", "--force", "--sign", "-", appBundle], {
      stdout: "pipe", stderr: "pipe",
    });
    if (await signProc.exited !== 0) {
      const errOutput = await new Response(signProc.stderr).text();
      process.stderr.write(`[zapp] warning: ad-hoc sign failed\n${errOutput}`);
    }

    // Need a booted sim to install onto. Tell the user clearly if
    // none is booted instead of erroring out cryptically inside simctl.
    const listed = Bun.spawnSync(["xcrun", "simctl", "list", "devices", "booted"], {
      stdout: "pipe", stderr: "ignore",
    });
    const bootedOut = listed.stdout.toString();
    if (!/\(Booted\)/.test(bootedOut)) {
      process.stderr.write(
        "[zapp] no iOS Simulator booted. Boot one first:\n" +
        "         xcrun simctl boot \"iPhone 17\"   # or any device from\n" +
        "         xcrun simctl list devices available\n"
      );
      killProc(viteProc);
      process.exit(1);
    }

    // Terminate any prior instance — install on top of a running app
    // can quietly skip the swap. simctl terminate exits 0 on "wasn't
    // running" too, so safe to fire-and-ignore.
    const bundleIdForTerm = config.identifier ?? `com.zapp.${exeName}.dev`;
    Bun.spawnSync(["xcrun", "simctl", "terminate", "booted", bundleIdForTerm], {
      stdout: "ignore", stderr: "ignore",
    });

    process.stdout.write("[zapp] installing on booted simulator...\n");
    const installProc = Bun.spawn(["xcrun", "simctl", "install", "booted", appBundle], {
      stdout: "pipe", stderr: "pipe",
    });
    if (await installProc.exited !== 0) {
      const errOutput = await new Response(installProc.stderr).text();
      process.stderr.write(`[zapp] simctl install failed\n${errOutput}`);
      killProc(viteProc);
      process.exit(1);
    }

    const bundleId = config.identifier ?? `com.zapp.${exeName}.dev`;
    process.stdout.write(`[zapp] launching ${bundleId}...\n`);
    // --console-pty captures stderr (txiki uses fprintf, not NSLog —
    // see reference_ios_wkwebview_drop). User sees the same output
    // they'd get from a desktop dev run.
    appProc = Bun.spawn(
      ["xcrun", "simctl", "launch", "--console-pty", "booted", bundleId],
      { cwd: root, stdout: "inherit", stderr: "inherit" }
    );

    // Wait for either Vite or the launch wrapper to exit. Note the
    // launch wrapper exits when the user terminates the app on the sim
    // (via the close button, app switcher, or simctl terminate). We
    // tear down Vite at that point to keep the dev session lean.
    const exitCode = await Promise.race([
      appProc.exited,
      viteProc.exited,
    ]);
    cleanup(exitCode as number);
    return;
  }

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

  appProc = Bun.spawn([execPath], {
    cwd: root,
    stdout: "inherit",
    stderr: "inherit",
  });

  // Wait for either to exit
  const exitCode = await Promise.race([
    appProc.exited,
    viteProc.exited,
  ]);

  cleanup(exitCode as number);
}

async function runBuild(root: string) {
  if (process.platform !== "darwin" && process.platform !== "win32") {
    process.stderr.write("[zapp] build is currently macOS and Windows only.\n");
    process.exit(1);
  }

  const target: BuildTarget = detectTarget();
  // iOS targets only build on macOS (Xcode SDK requirement).
  if (isIOSTarget(target) && process.platform !== "darwin") {
    process.stderr.write("[zapp] iOS builds require macOS host (Xcode SDK).\n");
    process.exit(1);
  }
  if (isIOSTarget(target)) {
    process.stdout.write(`[zapp] target: ${target}\n`);
  }

  const config = await loadConfig(root);
  const nativeDir = resolveNativeDir();

  // 0. Check worker engine
  const workerEngine = await hasAnyWorkerEngine(root);
  if (!workerEngine) {
    process.stderr.write(
      "[zapp] no worker engine defined in zapp/build.zc.\n" +
      "  Add one of:\n" +
      "    //> macos: define: ZAPP_WORKER_ENGINE_JSC    (zero binary cost, macOS-only)\n" +
      "    //> define: ZAPP_WORKER_ENGINE_TXIKI          (cross-platform, +6MB, web APIs)\n"
    );
    process.exit(1);
  }

  // 1. Generate service bindings + bundle workers
  process.stdout.write("[zapp] scanning for services...\n");
  const count = await generateBindings(root);
  if (count > 0) process.stdout.write(`[zapp] generated ${count} binding(s) in src/zapp/\n`);
  // Workers are bundled by the Vite plugin during vite build

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

  // 4. Build txiki.js if opted in (first time only). Per-target build
  // dirs — iOS Sim + iOS device share the macOS source tree but get
  // their own out-of-tree static libs.
  if (workerEngine === "txiki") {
    await ensureTxikiBuilt(nativeDir, target);
  }

  // 5. Generate build config + bootstrap (prod mode, embedded assets)
  const buildConfigFile = await generateBuildConfig({ root, config, mode: "prod", embedAssets: true });
  const platformFile = await generatePlatformConfig(root, target);
  const headlessFile = await generateHeadlessWorkers({ root, headless: config.headless });
  const bootstrapFile = await generateBootstrap(zappDir);

  // 5. Compile native binary (assets embedded in binary)
  process.stdout.write("[zapp] compiling native binary...\n");
  // Output paths differ by target. macOS / Windows: bin/<name>(.exe).
  // iOS: bin/ios/<name>.app/<name> — the binary lives inside a bundle
  // since simctl install / .ipa packaging both expect the bundled
  // structure. We create the bundle skeleton here; webview asset
  // embedding still happens the same way (in-binary).
  const binDir = path.join(root, "bin");
  await mkdir(binDir, { recursive: true });
  const exeName = config.name.replace(/\s+/g, "-").toLowerCase();
  const buildExeSuffix = process.platform === "win32" ? ".exe" : "";
  let nativeOut: string;
  if (isIOSTarget(target)) {
    const appBundle = path.join(binDir, "ios", `${config.name}.app`);
    await mkdir(appBundle, { recursive: true });
    nativeOut = path.join(appBundle, exeName);
  } else {
    nativeOut = path.join(binDir, exeName + buildExeSuffix);
  }

  const userBuildFile = path.join(root, "zapp", "build.zc");
  // For iOS, swap user's build.zc for a CLI-generated overlay that
  // strips `//> macos:` directives (zc gates those by host, not build
  // target) and re-emits iOS-appropriate ones.
  const buildFile = isIOSTarget(target)
    ? await generateIOSBuildFile(root, userBuildFile)
    : userBuildFile;
  await compileNative({
    root,
    buildFile,
    buildConfigFile,
    bootstrapFile,
    assetsFile,
    headlessFile,
    output: nativeOut,
    nativeDir,
    optimize: true,
    target,
  });

  // For iOS, write a minimal Info.plist next to the binary so simctl
  // install will accept the bundle. Real Phase 3 packaging adds icons,
  // entitlements, code-sign, etc. — this is the spike-grade plist
  // that just makes the app launch.
  if (isIOSTarget(target)) {
    await writeIOSDevPlist({ binaryPath: nativeOut, config, target });
    // Re-sign the bundle ad-hoc so the Info.plist is bound into the
    // signature. clang's linker emits an `adhoc,linker-signed` blob
    // covering only the Mach-O — modern iOS Simulator (macOS Sequoia+)
    // refuses to launch bundles whose Info.plist isn't sealed by the
    // code signature, with FBSOpenApplicationServiceErrorDomain code 4.
    // Real signing for device builds is Phase 3; this just makes
    // Simulator happy.
    const appBundle = path.dirname(nativeOut);
    const signProc = Bun.spawn(["codesign", "--force", "--sign", "-", appBundle], {
      stdout: "pipe", stderr: "pipe",
    });
    const signExit = await signProc.exited;
    if (signExit !== 0) {
      const errOutput = await new Response(signProc.stderr).text();
      process.stderr.write(`[zapp] warning: ad-hoc sign failed (exit ${signExit})\n${errOutput}`);
    }
    // Surface the launch invocation so the user doesn't have to dig
    // into Info.plist for the bundle ID. simctl's identifier is
    // CFBundleIdentifier, which is `config.identifier` (or our
    // generated fallback when omitted).
    const bundleId = config.identifier ?? `com.zapp.${config.name.replace(/\s+/g, "-").toLowerCase()}.dev`;
    process.stdout.write(
      `[zapp] iOS bundle: ${appBundle}\n` +
      `[zapp] to install + launch:\n` +
      `         xcrun simctl install booted ${path.relative(root, appBundle)}\n` +
      `         xcrun simctl launch --console booted ${bundleId}\n`
    );
  }

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
