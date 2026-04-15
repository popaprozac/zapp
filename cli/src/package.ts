// Production .app bundle creation.
// Copies binary + Vite assets into a proper macOS .app structure.
// Supports icons: .png (→ asset catalog, liquid glass on macOS 26+), .icns, .iconset

import path from "node:path";
import { mkdir, cp, chmod, rm } from "node:fs/promises";
import { existsSync } from "node:fs";
import type { ResolvedConfig } from "./config";
import { processIcon, type IconResult } from "./icon";
import { resolveAssetsDir } from "./paths";

interface PackageOptions {
  root: string;
  binaryPath: string;
  config: ResolvedConfig;
  sign?: boolean;
  notarize?: boolean;
}

export async function createProductionBundle(opts: PackageOptions): Promise<string> {
  const { root, binaryPath, config, sign, notarize } = opts;
  const appName = config.name.replace(/[^a-zA-Z0-9 _-]/g, "");
  const execName = appName.toLowerCase().replace(/\s+/g, "-");
  const outDir = path.join(root, "release", `${appName}.app`);
  const contentsDir = path.join(outDir, "Contents");
  const macOSDir = path.join(contentsDir, "MacOS");
  const resourcesDir = path.join(contentsDir, "Resources");

  // Clean previous bundle
  if (existsSync(outDir)) await rm(outDir, { recursive: true });

  // Create .app structure
  await mkdir(macOSDir, { recursive: true });
  await mkdir(resourcesDir, { recursive: true });

  // Copy binary
  const execPath = path.join(macOSDir, execName);
  await Bun.write(execPath, Bun.file(binaryPath));
  await chmod(execPath, 0o755);

  // Copy Vite build output into Resources/ (skip if assets are embedded in binary)
  // Check if this is an embedded build by looking at the binary size vs a threshold
  // Assets are embedded when `zapp build` runs (which runPackage calls first)
  const assetSrc = path.resolve(root, config.assetDir);
  // Only copy assets if they're NOT embedded in the binary
  // The build step sets use_embedded_assets=1, so we skip the copy
  const zappAssetsFile = path.join(root, ".zapp", "zapp_assets.zc");
  if (existsSync(zappAssetsFile)) {
    process.stdout.write("[zapp] assets embedded in binary (skipping resource copy)\n");
  } else if (existsSync(assetSrc)) {
    await cp(assetSrc, resourcesDir, { recursive: true });
    process.stdout.write(`[zapp] bundled assets from ${config.assetDir}\n`);
  } else {
    process.stderr.write(`[zapp] warning: asset directory not found: ${assetSrc}\n`);
  }

  // Copy worker scripts into .app bundle (workers load from filesystem, not embedded)
  const workersDir = path.join(root, ".zapp", "workers");
  if (existsSync(workersDir)) {
    const bundleWorkersDir = path.join(resourcesDir, ".zapp", "workers");
    await mkdir(bundleWorkersDir, { recursive: true });
    await cp(workersDir, bundleWorkersDir, { recursive: true });
    process.stdout.write("[zapp] bundled worker scripts\n");
  }

  // Process app icon — user-configured or framework default
  const macosConfig = config.macos;
  let iconResult: IconResult | null = null;

  let iconSrc = "";
  if (macosConfig?.icon) {
    iconSrc = path.resolve(root, macosConfig.icon);
  }
  if (!iconSrc || !existsSync(iconSrc)) {
    const frameworkAssets = resolveAssetsDir();
    if (frameworkAssets) {
      const defaultIcon = path.join(frameworkAssets, "zapp.icon");
      const defaultPng = path.join(frameworkAssets, "zapp.png");
      if (existsSync(defaultIcon)) iconSrc = defaultIcon;
      else if (existsSync(defaultPng)) iconSrc = defaultPng;
    }
  }

  if (iconSrc && existsSync(iconSrc)) {
      const tempDir = path.join(root, ".zapp", "icon-tmp");
      await mkdir(tempDir, { recursive: true });
      try {
        iconResult = await processIcon(iconSrc, tempDir);
        // Copy icon files into Resources/
        for (const file of iconResult.files) {
          const destPath = path.join(resourcesDir, file.dest);
          const { stat: fsStat } = await import("node:fs/promises");
          const srcStat = await fsStat(file.src);
          if (srcStat.isDirectory()) {
            await cp(file.src, destPath, { recursive: true });
          } else {
            await Bun.write(destPath, Bun.file(file.src));
          }
        }
        const format = iconResult.type === "assetcatalog" ? "asset catalog (liquid glass)" : ".icns";
        process.stdout.write(`[zapp] bundled icon: ${format}\n`);
      } finally {
        await rm(tempDir, { recursive: true, force: true });
      }
  }

  // Generate Info.plist
  const identifier = config.identifier ?? `com.zapp.${appName.toLowerCase().replace(/[^a-z0-9]/g, "")}`;
  const version = config.version ?? "1.0.0";
  const minVersion = macosConfig?.minimumSystemVersion ?? "12.0";
  const category = macosConfig?.category ?? "";

  let plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${execName}</string>
    <key>CFBundleIdentifier</key>
    <string>${identifier}</string>
    <key>CFBundleName</key>
    <string>${appName}</string>
    <key>CFBundleDisplayName</key>
    <string>${appName}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>${version}</string>
    <key>CFBundleShortVersionString</key>
    <string>${version}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>${minVersion}</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>`;

  if (iconResult) {
    plist += `
    <key>${iconResult.plistKey}</key>
    <string>${iconResult.plistValue}</string>`;
    // Also add CFBundleIconFile for older macOS fallback
    if (iconResult.plistKey === "CFBundleIconName") {
      plist += `
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>`;
    }
  }

  if (category) {
    plist += `
    <key>LSApplicationCategoryType</key>
    <string>${category}</string>`;
  }

  // Deep link URL schemes
  const schemes = config.deepLinkSchemes;
  if (schemes && schemes.length > 0) {
    const schemesXml = schemes.map(s => `            <string>${s}</string>`).join("\n");
    plist += `
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>${identifier}</string>
            <key>CFBundleURLSchemes</key>
            <array>
${schemesXml}
            </array>
        </dict>
    </array>`;
  }

  plist += `
</dict>
</plist>`;

  await Bun.write(path.join(contentsDir, "Info.plist"), plist);

  // Code sign
  const identity = sign
    ? (macosConfig?.signingIdentity ?? "-")
    : "-";

  process.stdout.write(`[zapp] signing (${identity === "-" ? "ad-hoc" : identity})...\n`);
  const signProc = Bun.spawn(
    ["codesign", "--force", "--deep", "-s", identity, outDir],
    { stdout: "pipe", stderr: "pipe" }
  );
  const signExit = await signProc.exited;
  if (signExit !== 0) {
    const stderr = await new Response(signProc.stderr).text();
    process.stderr.write(`[zapp] signing failed: ${stderr}\n`);
  }

  // Notarize (if requested and identity is not ad-hoc)
  if (notarize && identity !== "-") {
    process.stdout.write("[zapp] notarizing (this may take a few minutes)...\n");

    const zipPath = path.join(path.dirname(outDir), `${appName}.zip`);
    const zipProc = Bun.spawn(
      ["ditto", "-c", "-k", "--keepParent", outDir, zipPath],
      { stdout: "pipe", stderr: "pipe" }
    );
    await zipProc.exited;

    const notarizeProc = Bun.spawn(
      ["xcrun", "notarytool", "submit", zipPath, "--keychain-profile", "zapp", "--wait"],
      { stdout: "inherit", stderr: "inherit" }
    );
    const notarizeExit = await notarizeProc.exited;

    if (notarizeExit === 0) {
      const stapleProc = Bun.spawn(
        ["xcrun", "stapler", "staple", outDir],
        { stdout: "pipe", stderr: "pipe" }
      );
      await stapleProc.exited;
      process.stdout.write("[zapp] notarization complete\n");
    } else {
      process.stderr.write("[zapp] notarization failed\n");
    }
  }

  // Report sizes
  const binaryStat = Bun.file(execPath);
  const appSize = await getDirectorySize(outDir);
  process.stdout.write(
    `[zapp] package complete: ${outDir}\n` +
    `  binary: ${Math.round(binaryStat.size / 1024)} KB\n` +
    `  total:  ${Math.round(appSize / 1024)} KB\n`
  );

  return outDir;
}

async function getDirectorySize(dir: string): Promise<number> {
  const { readdir, stat } = await import("node:fs/promises");
  let total = 0;
  const entries = await readdir(dir, { withFileTypes: true });
  for (const entry of entries) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      total += await getDirectorySize(fullPath);
    } else {
      const s = await stat(fullPath);
      total += s.size;
    }
  }
  return total;
}
