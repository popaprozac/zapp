// CEF (`webEngine:"chromium"`) build integration — macOS. GATED: nothing here
// runs unless resolveWebEngine(config) === "chromium" AND the target is macOS.
// The default `system` (WKWebView) build never imports this module.
//
// Two responsibilities, both promoted from the proven spike
// (spikes/cef-macos/{fetch-cef.sh,build.sh} — see
// docs/superpowers/specs/2026-07-05-cef-webengine-production-slice-macos-
// design.md and spikes/cef-macos/FINDINGS.md):
//
//   1. ensureCefFetched — resolve/cache the ~110 MB CEF minimal distribution
//      (Release framework + include/ tree) under vendor/cef, invoking
//      cli/scripts/fetch-cef.sh on a cache miss. The main-exe compile/link
//      surface (the CEF .c/.m {.compile.} + framework {.passL.}) is emitted by
//      renderPlatformNim (build-config.ts) from the root this returns.
//
//   2. bundleCefApp — assemble the output `.app` CEF's macOS runtime model
//      requires: the framework + the five Helper subprocess `.app`s into
//      Contents/Frameworks, with the @rpath install_name rewrite on the
//      Helper (build.sh's recipe). The Nim build otherwise emits a bare
//      `bin/<exe>` binary; a CEF app can't run without the bundle layout.

import path from "node:path";
import { existsSync } from "node:fs";
import { rm, mkdir, copyFile, chmod, unlink } from "node:fs/promises";
import { clog } from "./log";
import { resolveVendorDir } from "./paths";
import type { ResolvedConfig } from "./config";

// CEF cache root — the dir that ends up containing Release/ + include/.
// Sits under the same vendor/ tree as zjs / bare (gitignored: vendor/cef/).
export function resolveCefCacheDir(): string {
  return path.join(resolveVendorDir(), "cef");
}

// The promoted fetch script (cli/scripts/fetch-cef.sh). Sibling of src/ in both
// the monorepo and the published-npm layout.
function resolveFetchScript(): string {
  return path.join(import.meta.dir, "..", "scripts", "fetch-cef.sh");
}

// Resolve — fetching if needed — the CEF distribution root. Returns the dir
// containing `Release/Chromium Embedded Framework.framework` + `include/`.
// Cache hit: returns immediately (no download). Cache miss: runs the fetch
// script (~110 MB, first run only). The human may pre-run it too:
//   CEF_DEST=<vendor>/cef bash cli/scripts/fetch-cef.sh
export async function ensureCefFetched(): Promise<string> {
  const cacheDir = resolveCefCacheDir();
  const framework = path.join(
    cacheDir, "Release", "Chromium Embedded Framework.framework",
    "Chromium Embedded Framework",
  );
  const includeSentinel = path.join(cacheDir, "include", "capi", "cef_app_capi.h");
  if (existsSync(framework) && existsSync(includeSentinel)) return cacheDir;

  const script = resolveFetchScript();
  if (!existsSync(script)) {
    throw new Error(`[zapp] CEF fetch script missing: ${script}`);
  }
  clog(0, "fetching CEF binary distribution (~110 MB, first run only)...");
  const proc = Bun.spawn(["bash", script], {
    env: { ...process.env, CEF_DEST: cacheDir },
    stdout: "inherit",
    stderr: "inherit",
  });
  const code = await proc.exited;
  if (code !== 0 || !existsSync(framework) || !existsSync(includeSentinel)) {
    throw new Error(
      `[zapp] CEF fetch failed (exit ${code}). Run it manually:\n` +
      `  CEF_DEST=${cacheDir} bash ${script}\n` +
      `or pre-seed ${cacheDir} with a CEF macos-arm64 minimal distribution ` +
      `(must contain Release/ + include/).`,
    );
  }
  return cacheDir;
}

// The framework binary path inside a fetched CEF root.
function cefFrameworkBin(cefRoot: string): string {
  return path.join(
    cefRoot, "Release", "Chromium Embedded Framework.framework",
    "Chromium Embedded Framework",
  );
}

// The five standard CEF macOS Helper variants: name-suffix + bundle-id-suffix.
// The base ("") is the one zapp_cef_make_settings points browser_subprocess_path
// at (derived at runtime from CFBundleExecutable — see zapp_cef_mac_entry.m).
const CEF_HELPER_VARIANTS: Array<{ nameSuffix: string; idSuffix: string }> = [
  { nameSuffix: "", idSuffix: "" },
  { nameSuffix: " (Alerts)", idSuffix: ".alerts" },
  { nameSuffix: " (GPU)", idSuffix: ".gpu" },
  { nameSuffix: " (Plugin)", idSuffix: ".plugin" },
  { nameSuffix: " (Renderer)", idSuffix: ".renderer" },
];

function helperInfoPlist(helperName: string, bundleId: string): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>${helperName}</string>
  <key>CFBundleIdentifier</key><string>${bundleId}</string>
  <key>CFBundleName</key><string>${helperName}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
`;
}

function mainInfoPlist(exeName: string, config: ResolvedConfig): string {
  const bundleId = config.identifier ?? config.name ?? "com.zapp.app";
  const displayName = config.name ?? exeName;
  const version = config.version ?? "1.0";
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>${exeName}</string>
  <key>CFBundleIdentifier</key><string>${bundleId}</string>
  <key>CFBundleName</key><string>${exeName}</string>
  <key>CFBundleDisplayName</key><string>${displayName}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${version}</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
`;
}

// Compile the CEF Helper subprocess executable. CEF launches render/GPU/utility
// children from a SEPARATE executable (zapp_cef_mac_helper.c owns `main`, so it
// can't link into the main exe). The Helper's TUs are mac_helper.c +
// scheme_handler.c + bridge.c (bridge.c is the render-process half of the
// bridge; both it and scheme_handler.c are ObjC/Cocoa-free so they link into
// this Cocoa-free child). scheme_handler.c references three symbols the MAIN
// binary provides via Nim {.exportc.} modules but the Helper doesn't link:
//   - zapp_build_use_embedded_assets()  (strong extern)
//   - zapp_embedded_assets[] / zapp_embedded_assets_count  (declared
//     __attribute__((weak)), but that's a weak *reference* — macOS ld still
//     requires a definition; only weak_import resolves-to-NULL, which we can't
//     add without editing T1's source).
// So we link a tiny stub providing all three (a count-0 asset table, exactly
// mirroring assets.ts's dev stub). The Helper never serves assets — the
// scheme-handler FACTORY is installed browser-side only — so these are inert.
// Returns the compiled helper binary path.
async function compileHelperBinary(opts: {
  cefRoot: string;
  cefDir: string;
  buildDir: string;
  embedAssets: boolean;
}): Promise<string> {
  const { cefRoot, cefDir, buildDir, embedAssets } = opts;
  await mkdir(buildDir, { recursive: true });

  const stubPath = path.join(buildDir, "zapp_cef_helper_stub.c");
  await Bun.write(
    stubPath,
    `// AUTO-GENERATED (zapp CLI). Satisfies the strong/weak externs
// zapp_cef_scheme_handler.c pulls into the CEF Helper child (the real symbols
// are Nim {.exportc.} defs in the MAIN binary; the Helper never serves assets,
// so these are inert). Struct layout matches zapp_cef_scheme_handler.c's
// ZappEmbeddedAsset and cli/src/assets.ts's count-0 dev stub.
#include <stdint.h>
typedef struct {
  const char* path;
  uint8_t* data;
  int len;
  int uncompressed_len;
  int is_brotli;
} ZappEmbeddedAsset;
ZappEmbeddedAsset zapp_embedded_assets[1];
int zapp_embedded_assets_count = 0;
int zapp_build_use_embedded_assets(void) { return ${embedAssets ? 1 : 0}; }
`,
  );

  const helperBin = path.join(buildDir, "zapp-cef-helper.bin");
  const fwBin = cefFrameworkBin(cefRoot);
  const cc = Bun.spawnSync([
    "clang", "-std=c11", "-O2",
    path.join(cefDir, "zapp_cef_mac_helper.c"),
    path.join(cefDir, "zapp_cef_scheme_handler.c"),
    path.join(cefDir, "zapp_cef_bridge.c"),
    stubPath,
    "-I" + cefRoot,
    "-I" + cefDir,
    fwBin,
    "-lcompression", // scheme_handler.c brotli decode (compression_decode_buffer)
    "-Wl,-rpath,@executable_path/../../../",
    "-o", helperBin,
  ]);
  if (cc.exitCode !== 0) {
    throw new Error(
      "[zapp] failed to compile CEF Helper:\n" +
      new TextDecoder().decode(cc.stderr),
    );
  }

  // The framework's install_name is @executable_path/../Frameworks/... — correct
  // for the MAIN exe (at Contents/MacOS) but wrong for a Helper exe three levels
  // deeper. Rewrite the Helper's dependency to @rpath-relative; the rpath above
  // (@executable_path/../../../ -> the main app's Contents/Frameworks) resolves it.
  const change = Bun.spawnSync([
    "install_name_tool", "-change",
    "@executable_path/../Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework",
    "@rpath/Chromium Embedded Framework.framework/Chromium Embedded Framework",
    helperBin,
  ]);
  if (change.exitCode !== 0) {
    throw new Error(
      "[zapp] failed to rewrite CEF Helper framework path:\n" +
      new TextDecoder().decode(change.stderr),
    );
  }
  return helperBin;
}

// Assemble the output `.app` bundle a CEF app requires around the Nim-built
// binary. Adapts spikes/cef-macos/build.sh (framework -> Contents/Frameworks,
// five Helper .apps, install_name @rpath rewrite). Leaves the main exe's
// framework dependency untouched: it's @executable_path/../Frameworks/... which
// already resolves from Contents/MacOS.
export async function bundleCefApp(opts: {
  nativeBinary: string;    // the Nim-built binary (bin/<exe>)
  appPath: string;         // output bundle (bin/<exe>.app)
  exeName: string;         // CFBundleExecutable + Contents/MacOS/<exeName> + Helper base name
  cefRoot: string;         // fetched CEF distribution root
  nativeDir: string;       // framework native/ (for platform/darwin/cef sources)
  config: ResolvedConfig;  // Info.plist identity
  buildDir: string;        // scratch dir for the helper binary + stub (.zapp/)
  embedAssets: boolean;    // helper stub return value (prod=1/dev=0)
}): Promise<void> {
  const { nativeBinary, appPath, exeName, cefRoot, nativeDir, config, buildDir, embedAssets } = opts;
  const cefDir = path.join(nativeDir, "platform", "darwin", "cef");
  const bundleId = config.identifier ?? config.name ?? "com.zapp.app";

  const contents = path.join(appPath, "Contents");
  const macosDir = path.join(contents, "MacOS");
  const frameworksDir = path.join(contents, "Frameworks");

  await rm(appPath, { recursive: true, force: true });
  await mkdir(macosDir, { recursive: true });
  await mkdir(frameworksDir, { recursive: true });

  // 1. Main executable — copy the Nim binary into Contents/MacOS/<exeName>.
  const mainExe = path.join(macosDir, exeName);
  await copyFile(nativeBinary, mainExe);
  await chmod(mainExe, 0o755);

  // 2. CEF framework -> Contents/Frameworks (ditto preserves the bundle's
  //    symlinks + code signature).
  const fwSrc = path.join(cefRoot, "Release", "Chromium Embedded Framework.framework");
  const fwDst = path.join(frameworksDir, "Chromium Embedded Framework.framework");
  const ditto = Bun.spawnSync(["ditto", fwSrc, fwDst]);
  if (ditto.exitCode !== 0) {
    throw new Error(
      "[zapp] failed to copy CEF framework into the bundle:\n" +
      new TextDecoder().decode(ditto.stderr),
    );
  }

  // 3. Compile the Helper subprocess executable once.
  const helperBin = await compileHelperBinary({ cefRoot, cefDir, buildDir, embedAssets });

  // 4. The five Helper .app bundles. Base name derives from the main exe name
  //    (matches zapp_cef_mac_entry.m's runtime CFBundleExecutable-based lookup).
  for (const { nameSuffix, idSuffix } of CEF_HELPER_VARIANTS) {
    const helperName = `${exeName} Helper${nameSuffix}`;
    const helperApp = path.join(frameworksDir, `${helperName}.app`);
    const helperMacos = path.join(helperApp, "Contents", "MacOS");
    await mkdir(helperMacos, { recursive: true });
    const helperExe = path.join(helperMacos, helperName);
    await copyFile(helperBin, helperExe);
    await chmod(helperExe, 0o755);
    await Bun.write(
      path.join(helperApp, "Contents", "Info.plist"),
      helperInfoPlist(helperName, `${bundleId}.helper${idSuffix}`),
    );
  }
  await unlink(helperBin).catch(() => {});

  // 5. Main Info.plist.
  await Bun.write(path.join(contents, "Info.plist"), mainInfoPlist(exeName, config));
}
