#!/usr/bin/env bun
import path from "node:path";
import process from "node:process";
import { mkdir, rm, cp } from "node:fs/promises";
import { existsSync } from "node:fs";
import {
  createConfigContext,
  loadConfig,
  WORKER_MODULE_CAPABILITIES,
  type ResolvedConfig,
  type WorkerModuleId,
  type ZappConfigCommand,
} from "./config";
import { generateBuildConfig, generatePlatformConfig, generateHeadlessWorkers, generateIOSBuildFile, generateEngineOverlay } from "./build-config";
import { generateBindings } from "./generate";
import { compileNative, ensureBareBuilt, bareEnginesEnabled, hasAnyWorkerEngine, detectTarget, isIOSTarget, type BuildTarget } from "./native";
import { resolveNativeDir, resolveBootstrapDir, resolveIOSIconPng } from "./paths";
import { buildIOSAssetCatalog } from "./icon";
import { runInit } from "./init";
// bundleWorkers removed — Vite plugin handles worker bundling now
import { createDevBundle } from "./bundle";
import { createProductionBundle } from "./package";
import { generateAssetManifest } from "./assets";
import { setCliLevel, levelFromArgv, getCliLevel, envFromLevel, clog, clogError } from "./log";
import { nativeLanguage } from "./native-lang";

// Bootstrap codegen lives outside cli/ in the monorepo but is bundled
// alongside it in the published package. Dynamic import so the path
// can be resolved at runtime for both layouts.
const bootstrapDir = resolveBootstrapDir();
const { generateBootstrap } = await import(path.join(bootstrapDir, "codegen.ts"));

const cwd = process.cwd();

// Resolve a PNG icon for iOS, compile it to Assets.car, copy it into the
// .app, and return "AppIcon" (the CFBundleIconName) — or null if no PNG
// icon is available or actool fails (the build proceeds without an icon).
async function prepareIOSIcon(
  root: string,
  config: { ios?: { icon?: string; minimumSystemVersion?: string }; macos?: { icon?: string } },
  target: BuildTarget,
  appBundle: string,
): Promise<{ iconName: string; plistFragment: string } | null> {
  if (!isIOSTarget(target)) return null;
  const png = resolveIOSIconPng(root, config);
  if (!png) {
    clog(0, "[zapp] no PNG app icon for iOS (ios.icon / build/ios/icon.png / build/icon.png / macOS icon / framework default) — skipping icon");
    return null;
  }
  const tempDir = path.join(root, ".zapp", "ios-icon-tmp");
  await rm(tempDir, { recursive: true, force: true });
  await mkdir(tempDir, { recursive: true });
  try {
    const result = await buildIOSAssetCatalog(
      png, tempDir,
      target === "ios-device" ? "ios-device" : "ios-simulator",
      config.ios?.minimumSystemVersion ?? "15.0",
    );
    if (!result) return null;
    for (const f of result.files) {
      await cp(f.src, path.join(appBundle, f.dest));
    }
    // plistValue = "AppIcon" (top-level CFBundleIconName); plistFragment =
    // actool's CFBundleIcons / CFBundleIcons~ipad dicts that SpringBoard
    // needs to actually render the home-screen icon.
    return { iconName: result.plistValue, plistFragment: result.plistFragment ?? "" };
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

// Minimal Info.plist for iOS dev/spike builds. Enough for simctl
// install + launch to succeed; production packaging (Phase 3) replaces
// this with the full plist + icons + entitlements path.
async function writeIOSDevPlist(opts: {
  binaryPath: string;
  config: { name: string; identifier?: string; version?: string; ios?: { minimumSystemVersion?: string; deviceFamily?: string } };
  target: BuildTarget;
  iconName?: string | null;
  iconPlistFragment?: string | null;
}): Promise<void> {
  const { binaryPath, config, target, iconName, iconPlistFragment } = opts;
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
  ${iconName ? `<key>CFBundleIconName</key><string>${iconName}</string>` : ""}
  ${iconPlistFragment ?? ""}
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

/**
 * Walk the user's `workerModules` declaration and surface any package
 * that's named in the capability registry but isn't actually installed
 * in their `node_modules/`. We don't auto-install today (that's a
 * deeper UX call — `--auto-install` flag tracked separately); the
 * warning hands the user a one-liner to run.
 *
 * No-op when `workerModules` is empty or unset.
 */
async function verifyWorkerModules(
  root: string,
  workerModules: WorkerModuleId[] | undefined,
): Promise<void> {
  if (!workerModules || workerModules.length === 0) return;
  const missing: Array<{ capability: WorkerModuleId; pkg: string }> = [];
  for (const cap of workerModules) {
    const spec = WORKER_MODULE_CAPABILITIES[cap];
    if (!spec) {
      clogError(`warning: unknown workerModules entry '${cap}'`);
      continue;
    }
    for (const pkg of spec.packages) {
      const pkgPath = path.join(root, "node_modules", pkg, "package.json");
      if (!existsSync(pkgPath)) missing.push({ capability: cap, pkg });
    }
  }
  if (missing.length === 0) return;
  clogError("workerModules: missing packages —");
  for (const { capability, pkg } of missing) {
    process.stderr.write(`  - "${capability}" needs '${pkg}'\n`);
  }
  const all = missing.map((m) => m.pkg).join(" ");
  clogError(`run:  bun install ${all}`);
}

async function runDev(root: string) {
  if (process.platform !== "darwin" && process.platform !== "win32") {
    clogError("dev mode is currently macOS, iOS, and Windows only.");
    process.exit(1);
  }

  const target: BuildTarget = detectTarget();
  if (nativeLanguage() === "z") {
    throw new Error(
      "[zapp] ZAPP_NATIVE_LANG=z currently supports `zapp build` and the " +
      "message-boundary smoke. Interactive dev starts with the Phase 1 WebView core.",
    );
  }
  if (isIOSTarget(target) && process.platform !== "darwin") {
    clogError("iOS dev requires macOS host (Xcode SDK).");
    process.exit(1);
  }

  const config = await loadConfig(
    root,
    createConfigContext(root, "dev", target),
  );
  const nativeDir = resolveNativeDir();
  const port = config.devPort ?? 5173;
  // iOS Simulator on Apple Silicon shares host network namespace, so
  // localhost from inside the sim resolves to the same Vite dev server
  // the host is binding. No special tunnel needed.
  const devUrl = `http://localhost:${port}`;
  const isIOS = isIOSTarget(target);
  if (isIOS) {
    clog(0, `target: ${target}`);
  }

  // 0. Check worker engine. Project either declares one in build.zc OR
  // names one (or many) in zapp.config.ts headless map; we generate an
  // overlay below to bridge the latter into the build. If a project has
  // workers but neither, we default to the platform's bare engine.
  const workerEngine = await hasAnyWorkerEngine(root);
  const hasHeadlessWorkers = !!(config.headless && Object.keys(config.headless).length > 0);
  if (!workerEngine && !hasHeadlessWorkers) {
    // No workers anywhere. The build still succeeds — the user just
    // doesn't get the worker subsystem. Webview Workers still work.
    clog(0, "no worker engine configured — workers disabled.");
  }

  // 0a. workers.modules — verify each declared capability's
  //     underlying packages are installed in the project. Today we
  //     warn only; future iteration may auto-install.
  await verifyWorkerModules(root, config.workerModules);

  // 1. Generate engine overlay (auto-define engines named in headless
  //    config but not declared in build.zc). Must run BEFORE the engine
  //    builds below so bareEnginesEnabled sees the generated overlay
  //    too.
  const engineOverlayFile = await generateEngineOverlay({ root, target, config });

  // 1a. iOS-specific: generate the platform-scoped build file NOW so
  //     the engine probes below see the iOS-correct directives instead
  //     of the user's macos:-prefixed ones (which the zc compiler
  //     drops on iOS but our regex-scan would otherwise honor —
  //     e.g. trying to build bare-v8 for iOS even though iOS uses
  //     bare-jsc).
  const userBuildFileEarly = path.join(root, "zapp", "build.zc");
  const iosBuildFile = isIOS
    ? await generateIOSBuildFile(root, userBuildFileEarly, config)
    : null;

  // 2. Generate service bindings + bundle workers
  clog(1, "scanning for services...");
  const count = await generateBindings(root);
  if (count > 0) clog(1, `generated ${count} binding(s) in src/zapp/`);
  // Workers are bundled by the Vite plugin during vite build/dev

  // 3. Build vendored worker engines that the user opted into (either
  //    via build.zc directives or via the engine overlay). Each
  //    ZAPP_WORKER_ENGINE_* define enables one engine; multiple can
  //    coexist (the dispatcher routes per-worker at runtime). First
  //    build is slow (~3-5 min for Bare with engine-from-source);
  //    subsequent runs reuse the cached `_deps/` tree.
  for (const bareEngine of await bareEnginesEnabled(
    root, engineOverlayFile ?? undefined, target, iosBuildFile ?? undefined,
  )) {
    await ensureBareBuilt(nativeDir, target, bareEngine, root);
  }

  // 4. Generate build config + bootstrap (dev mode)
  const buildConfigFile = await generateBuildConfig({ root, config, mode: "dev", devUrl, target });
  const platformFile = await generatePlatformConfig(root, target, iosBuildFile ?? undefined, engineOverlayFile ?? undefined, config);
  const headlessFile = await generateHeadlessWorkers({ root, headless: config.headless });
  const zappDir = path.join(root, ".zapp");
  clog(1, "generating bootstrap...");
  const bootstrapFile = await generateBootstrap(zappDir);

  // Generate stub assets file (no embedded assets in dev, but symbols must exist for linking)
  const stubAssets = `// Stub — no embedded assets in dev mode.\nraw {\n` +
    `    #if defined(__APPLE__)\n` +
    `    #include <compression.h>\n` +
    `    #endif\n` +
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
      clogError(
        `port ${port} is already in use (pid ${pids.join(", ")}).\n` +
        `  Likely a stale Vite from a previous dev run. Run:\n` +
        `    kill ${pids.join(" ")}`
      );
      process.exit(1);
    }
  } else {
    // Windows: netstat instead of lsof. Without this check a stale
    // Vite from a crashed dev run keeps the port, our new Vite dies on
    // --strictPort, and the app silently loads the STALE server's old
    // bundle — the most confusing failure mode dev mode has.
    const ns = Bun.spawnSync(["netstat", "-ano", "-p", "TCP"], { stdout: "pipe", stderr: "ignore" });
    const pids = new Set<string>();
    for (const line of ns.stdout.toString().split("\n")) {
      if (line.includes(`:${port}`) && line.includes("LISTENING")) {
        const pid = line.trim().split(/\s+/).pop();
        if (pid && pid !== "0") pids.add(pid);
      }
    }
    if (pids.size > 0) {
      const list = [...pids];
      clogError(
        `port ${port} is already in use (pid ${list.join(", ")}).\n` +
        `  Likely a stale Vite from a previous dev run. Run:\n` +
        `    taskkill /F /PID ${list.join(" /PID ")}`
      );
      process.exit(1);
    }
  }

  clog(1, "starting vite dev server...");
  const viteProc = Bun.spawn(["bunx", "vite", "--port", String(port), "--strictPort"], {
    cwd: root,
    stdout: "inherit",
    stderr: "inherit",
    // Spread process.env so the vite plugin sees the runtime-set ZAPP_LOG
    // (Bun.spawn otherwise snapshots env at process start, missing mutations).
    env: { ...process.env },
  });

  // Wait for Vite to be ready — but also fail fast if the spawned process dies
  // (e.g. plugin error during startup).
  const ready = await Promise.race([
    waitForPort(port),
    viteProc.exited.then(() => "vite-died" as const),
  ]);
  if (ready !== true) {
    clogError(`vite dev server failed to start on port ${port}`);
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
    clogError("uncaught exception:", (err as Error)?.stack ?? err);
    cleanup(1);
  });
  process.on("unhandledRejection", (err) => {
    clogError("unhandled rejection:", (err as Error)?.stack ?? err);
    cleanup(1);
  });

  // 4. Compile native binary. If this throws, cleanup() above kills vite.
  clog(1, "compiling native binary...");
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

  // For iOS we already generated `_zapp_build_ios.zc` earlier (so
  // the engine-build probes could see iOS-correct directives). Reuse
  // it here instead of regenerating.
  const buildFile = iosBuildFile ?? path.join(root, "zapp", "build.zc");

  try {
    await compileNative({
      root,
      buildFile,
      buildConfigFile,
      bootstrapFile,
      assetsFile,
      headlessFile,
      engineOverlayFile: engineOverlayFile ?? undefined,
      output: nativeOut,
      nativeDir,
      optimize: false,
      devUrl,
      config,
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
    const appBundle = path.dirname(nativeOut);
    const iconInfo = await prepareIOSIcon(root, config, target, appBundle);
    await writeIOSDevPlist({
      binaryPath: nativeOut, config, target,
      iconName: iconInfo?.iconName ?? null,
      iconPlistFragment: iconInfo?.plistFragment ?? null,
    });
    const signProc = Bun.spawn(["codesign", "--force", "--sign", "-", appBundle], {
      stdout: "pipe", stderr: "pipe",
    });
    if (await signProc.exited !== 0) {
      const errOutput = await new Response(signProc.stderr).text();
      clogError(`warning: ad-hoc sign failed\n${errOutput}`);
    }

    // Need a booted sim to install onto. Tell the user clearly if
    // none is booted instead of erroring out cryptically inside simctl.
    const listed = Bun.spawnSync(["xcrun", "simctl", "list", "devices", "booted"], {
      stdout: "pipe", stderr: "ignore",
    });
    const bootedOut = listed.stdout.toString();
    if (!/\(Booted\)/.test(bootedOut)) {
      clogError(
        "no iOS Simulator booted. Boot one first:\n" +
        "         xcrun simctl boot \"iPhone 17\"   # or any device from\n" +
        "         xcrun simctl list devices available"
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

    clog(0, "installing on booted simulator...");
    const installProc = Bun.spawn(["xcrun", "simctl", "install", "booted", appBundle], {
      stdout: "pipe", stderr: "pipe",
    });
    if (await installProc.exited !== 0) {
      const errOutput = await new Response(installProc.stderr).text();
      clogError(`simctl install failed\n${errOutput}`);
      killProc(viteProc);
      process.exit(1);
    }

    const bundleId = config.identifier ?? `com.zapp.${exeName}.dev`;
    clog(0, `launching ${bundleId}...`);
    // --console-pty captures stderr (workers use fprintf for dev logs).
    // User sees the same output they'd get from a desktop dev run.
    appProc = Bun.spawn(
      ["xcrun", "simctl", "launch", "--console-pty", "booted", bundleId],
      {
        cwd: root,
        stdout: "inherit",
        stderr: "inherit",
        // simctl forwards SIMCTL_CHILD_<VAR> to the launched app's env, so
        // the app's getenv("ZAPP_LOG") sees the CLI's chosen log level.
        env: { ...process.env, SIMCTL_CHILD_ZAPP_LOG: envFromLevel(getCliLevel()) },
      }
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
    clog(1, "creating dev bundle...");
    const appDir = await createDevBundle(root, nativeOut, config);
    const execName = path.basename(nativeOut);
    execPath = path.join(appDir, "Contents", "MacOS", execName);
    clog(0, `launching ${appDir}`);
  } else {
    // Windows: self-contained WebView2 loader — no external DLL needed
    execPath = nativeOut;
    clog(0, `launching ${execPath}`);
  }

  appProc = Bun.spawn([execPath], {
    cwd: root,
    stdout: "inherit",
    stderr: "inherit",
    // Bun.spawn with no env: inherits a start-time snapshot of process.env,
    // not runtime mutations. Spread the current env so the ZAPP_LOG we set
    // during dispatch reaches the app's getenv("ZAPP_LOG").
    env: { ...process.env, ZAPP_LOG: envFromLevel(getCliLevel()) },
  });

  // Wait for either to exit
  const exitCode = await Promise.race([
    appProc.exited,
    viteProc.exited,
  ]);

  cleanup(exitCode as number);
}

async function runBuild(
  root: string,
  configCommand: Extract<ZappConfigCommand, "build" | "package"> = "build",
): Promise<ResolvedConfig> {
  if (process.platform !== "darwin" && process.platform !== "win32") {
    clogError("build is currently macOS and Windows only.");
    process.exit(1);
  }

  const target: BuildTarget = detectTarget();
  // iOS targets only build on macOS (Xcode SDK requirement).
  if (isIOSTarget(target) && process.platform !== "darwin") {
    clogError("iOS builds require macOS host (Xcode SDK).");
    process.exit(1);
  }
  if (isIOSTarget(target)) {
    clog(0, `target: ${target}`);
  }

  const config = await loadConfig(
    root,
    createConfigContext(root, configCommand, target),
  );
  const nativeDir = resolveNativeDir();

  // 0. Check worker engine. Workers are opt-in: a project either
  // declares one in build.zc OR names one in zapp.config.ts headless
  // map (auto-overlay below pulls it into the build). When neither
  // exists, workers are silently disabled and the binary stays small.
  const workerEngine = await hasAnyWorkerEngine(root);
  const hasHeadlessWorkers = !!(config.headless && Object.keys(config.headless).length > 0);
  if (!workerEngine && !hasHeadlessWorkers) {
    clog(0, "no worker engine configured — workers disabled.");
  }

  await verifyWorkerModules(root, config.workerModules);

  // 1. Generate service bindings + bundle workers
  clog(1, "scanning for services...");
  const count = await generateBindings(root);
  if (count > 0) clog(1, `generated ${count} binding(s) in src/zapp/`);
  // Workers are bundled by the Vite plugin during vite build

  // 2. Build frontend with Vite
  clog(1, "building frontend...");
  const viteProc = Bun.spawn(["bunx", "vite", "build"], {
    cwd: root,
    stdout: "inherit",
    stderr: "inherit",
    // Spread process.env so the vite plugin sees the runtime-set ZAPP_LOG
    // (Bun.spawn otherwise snapshots env at process start, missing mutations).
    env: { ...process.env },
  });
  const viteExit = await viteProc.exited;
  if (viteExit !== 0) {
    clogError("vite build failed");
    process.exit(1);
  }

  // 3. Compress + embed assets with brotli.
  // The Nim build path emits its OWN asset module (+ the embed marker) inside
  // buildNativeNim via generateAssetManifestNim, so skip the zc emitter here —
  // running both doubles the brotli pass and leaves a dead .zapp/zapp_assets.zc.
  // (compileNative's nim branch ignores `assetsFile`.)
  const zappDir = path.join(root, ".zapp");
  let assetsFile: string | undefined;
  const selectedNativeLanguage = nativeLanguage();
  if (selectedNativeLanguage === "nim") {
    clog(1, "embedding assets with brotli (Nim emitter, in native build)...");
  } else if (selectedNativeLanguage === "zc") {
    clog(1, "embedding assets with brotli...");
    assetsFile = await generateAssetManifest(root, config.assetDir, config.compressAssets !== false);
  } else {
    // Phase 0 deliberately proves the Z archive/runtime/message boundary before
    // rebuilding the WebView asset loader in Z. Vite still validates and emits
    // the frontend; Phase 1 will consume it from the Z-owned application core.
    clog(1, "staging frontend assets for the Phase 0 Z core...");
  }

  if (selectedNativeLanguage === "z") {
    // The replacement core owns its native build graph. Do not run the legacy
    // engine overlay, platform config, generated zc/Nim bootstrap, or native
    // engine build merely because the old CLI historically did so.
    const binDir = path.join(root, "bin");
    await mkdir(binDir, { recursive: true });
    const exeName = config.name.replace(/\s+/g, "-").toLowerCase();
    const nativeOut = path.join(binDir, exeName);
    clog(1, "compiling Phase 0 Z native core...");
    await compileNative({
      root,
      buildFile: "",
      buildConfigFile: "",
      output: nativeOut,
      nativeDir,
      optimize: true,
      config,
      target,
    });
    const size = Bun.file(nativeOut).size;
    clog(0, `build complete: ${nativeOut} (${Math.round(size / 1024)} KB, Phase 0 Z core)`);
    return config;
  }

  // 4. Generate engine overlay (auto-defines for engines named in
  // zapp.config.ts headless map but not declared in build.zc) BEFORE
  // engine builds, so the build set sees the overlay too.
  const engineOverlayFile = await generateEngineOverlay({ root, target, config });

  // 5. Build vendored worker engines that the user opted into.
  // Per-target build dirs so iOS Sim + iOS device + macOS coexist.
  // First build per engine takes 1-5 min; cached `_deps/` reused after.
  for (const bareEngine of await bareEnginesEnabled(root, engineOverlayFile ?? undefined)) {
    await ensureBareBuilt(nativeDir, target, bareEngine, root);
  }

  // 6. Generate build config + bootstrap (prod mode, embedded assets)
  const buildConfigFile = await generateBuildConfig({ root, config, mode: "prod", embedAssets: true, target });
  const platformFile = await generatePlatformConfig(root, target, undefined, engineOverlayFile ?? undefined, config);
  const headlessFile = await generateHeadlessWorkers({ root, headless: config.headless });
  const bootstrapFile = await generateBootstrap(zappDir);

  // 5. Compile native binary (assets embedded in binary)
  clog(1, "compiling native binary...");
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
    ? await generateIOSBuildFile(root, userBuildFile, config)
    : userBuildFile;
  await compileNative({
    root,
    buildFile,
    buildConfigFile,
    bootstrapFile,
    assetsFile,
    headlessFile,
    engineOverlayFile: engineOverlayFile ?? undefined,
    output: nativeOut,
    nativeDir,
    optimize: true,
    config,
    target,
  });

  // For iOS, write a minimal Info.plist next to the binary so simctl
  // install will accept the bundle. Real Phase 3 packaging adds icons,
  // entitlements, code-sign, etc. — this is the spike-grade plist
  // that just makes the app launch.
  if (isIOSTarget(target)) {
    const iconInfo = await prepareIOSIcon(root, config, target, path.dirname(nativeOut));
    await writeIOSDevPlist({
      binaryPath: nativeOut, config, target,
      iconName: iconInfo?.iconName ?? null,
      iconPlistFragment: iconInfo?.plistFragment ?? null,
    });
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
      clogError(`warning: ad-hoc sign failed (exit ${signExit})\n${errOutput}`);
    }
    // Surface the launch invocation so the user doesn't have to dig
    // into Info.plist for the bundle ID. simctl's identifier is
    // CFBundleIdentifier, which is `config.identifier` (or our
    // generated fallback when omitted).
    const bundleId = config.identifier ?? `com.zapp.${config.name.replace(/\s+/g, "-").toLowerCase()}.dev`;
    clog(0,
      `iOS bundle: ${appBundle}\n` +
      `[zapp] to install + launch:\n` +
      `         xcrun simctl install booted ${path.relative(root, appBundle)}\n` +
      `         xcrun simctl launch --console booted ${bundleId}`
    );
  }

  const stat = Bun.file(nativeOut);
  const size = stat.size;
  clog(0, `build complete: ${nativeOut} (${Math.round(size / 1024)} KB)`);
  return config;
}

async function runPackage(root: string) {
  if (process.platform !== "darwin") {
    clogError("package is currently macOS-only.");
    process.exit(1);
  }
  if (nativeLanguage() === "z") {
    throw new Error(
      "[zapp] packaging the Z native core begins after the Phase 1 AppKit/WebKit vertical slice; use `zapp build` for Phase 0.",
    );
  }

  // Run a full build first
  const config = await runBuild(root, "package");
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
  clog(0, `generated ${count} binding(s) in src/zapp/`);
}

// --- CLI ---
const command = process.argv[2];
const root = path.resolve(cwd, process.argv.includes("-r")
  ? process.argv[process.argv.indexOf("-r") + 1] || "."
  : ".");

// Set the CLI log level once from argv (--verbose/-v → 1, --debug → 2).
// clog(level, …) lines below gate on this: 0 always prints, 1/2 are opt-in.
setCliLevel(levelFromArgv(process.argv.slice(2)));
// Export the level so cross-package consumers (the vite plugin, and later the
// spawned native app) read it from ONE source of truth. "" = default/quiet.
process.env.ZAPP_LOG = envFromLevel(getCliLevel());

try {
  switch (command) {
  case "init": {
    const name = process.argv[3] || "zapp-app";
    const tIdx = process.argv.indexOf("-t");
    const templateIdx = process.argv.indexOf("--template");
    // Explicit flag → resolved later in runInit; null → interactive prompt
    // unless --yes is passed (which uses the default = react-ts).
    const template = tIdx >= 0 ? process.argv[tIdx + 1]
      : templateIdx >= 0 ? process.argv[templateIdx + 1]
      : null;
    const yes = process.argv.includes("--yes") || process.argv.includes("-y");
    // --install / --no-install force a decision and skip the prompt.
    const install = process.argv.includes("--no-install") ? false
      : process.argv.includes("--install") ? true
      : null;
    await runInit({ name, template, root: cwd, yes, install });
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
    console.log("  init [name] [opts]         Scaffold a new project");
    console.log("                               -t,--template <name>  react|svelte|vue|solid|vanilla (default: prompt)");
    console.log("                               -y,--yes              accept defaults, skip prompts (react)");
    console.log("                               --install / --no-install  force the post-scaffold bun install");
    console.log("  dev                        Development mode with Vite HMR");
    console.log("  build                      Production build");
    console.log("  package [--sign] [--notarize]  Create .app bundle for distribution");
    console.log("  generate                   Generate service bindings");
    process.exit(1);
  }
} catch (error) {
  if (getCliLevel() >= 2 && error instanceof Error && error.stack) {
    clogError(error.stack);
  } else {
    const message = error instanceof Error ? error.message : String(error);
    clogError(message.startsWith("[zapp] ") ? message.slice(7) : message);
  }
  process.exitCode = 1;
}
