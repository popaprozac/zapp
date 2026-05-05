// Production .app bundle creation.
// Copies binary + Vite assets into a proper macOS .app structure.
// Supports icons: .png (→ asset catalog, liquid glass on macOS 26+), .icns, .iconset

import path from "node:path";
import { mkdir, cp, chmod, rm } from "node:fs/promises";
import { existsSync } from "node:fs";
import type { MacOSConfig, ResolvedConfig } from "./config";
import { processIcon, type IconResult } from "./icon";
import { resolveAppIconPath } from "./paths";
import { resolveEntitlements } from "./entitlements";
import { notarizeApp } from "./notarize";

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

  // Process app icon. Priority: macos.icon → build/macos/icon.* → framework default.
  // resolveAppIconPath handles the search; processIcon converts to bundle format.
  const macosConfig = config.macos;
  let iconResult: IconResult | null = null;
  const iconSrc = resolveAppIconPath(root, macosConfig?.icon);

  if (iconSrc) {
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
  const plist = await generateInfoPlist({
    root,
    appName,
    execName,
    config,
    iconResult,
  });
  await Bun.write(path.join(contentsDir, "Info.plist"), plist);

  // Code sign
  const identity = sign
    ? (macosConfig?.signingIdentity ?? "-")
    : "-";

  const entitlements = await resolveEntitlements(root, config);

  process.stdout.write(
    `[zapp] signing (${identity === "-" ? "ad-hoc" : identity})` +
    (entitlements.used ? ` with entitlements` : ``) +
    `...\n`
  );

  const codesignArgs = ["codesign", "--force", "--deep", "-s", identity];
  // Hardened runtime is required for Apple notarization. Always
  // enable it for non-ad-hoc signs — it has zero downside for apps
  // that aren't doing exotic memory tricks, and saves users the
  // mysterious "notarization rejected: hardened runtime" footgun.
  if (identity !== "-") {
    codesignArgs.push("--options", "runtime");
  }
  if (entitlements.used) {
    codesignArgs.push("--entitlements", entitlements.path);
  }
  codesignArgs.push(outDir);

  const signProc = Bun.spawn(codesignArgs, { stdout: "pipe", stderr: "pipe" });
  const signExit = await signProc.exited;
  if (signExit !== 0) {
    const stderr = await new Response(signProc.stderr).text();
    process.stderr.write(`[zapp] signing failed: ${stderr}\n`);
  }

  // Notarize: only meaningful with a real Developer ID. Ad-hoc signed
  // bundles can't be notarized — the user needs to set
  // `macos.signingIdentity` first. Surface that clearly.
  if (notarize) {
    if (identity === "-") {
      process.stderr.write(
        "[zapp] notarization skipped: ad-hoc signed bundle. " +
        "Set `macos.signingIdentity` to a Developer ID and rerun.\n"
      );
    } else {
      await notarizeApp({ appPath: outDir, notarize: macosConfig?.notarize });
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

// ---------------------------------------------------------------------------
// Info.plist generation
// ---------------------------------------------------------------------------

interface PlistGenOptions {
  root: string;
  appName: string;
  execName: string;
  config: ResolvedConfig;
  iconResult: IconResult | null;
}

const USAGE_DESC_KEYS: Record<string, string> = {
  camera: "NSCameraUsageDescription",
  microphone: "NSMicrophoneUsageDescription",
  location: "NSLocationUsageDescription",
  photos: "NSPhotoLibraryUsageDescription",
  documents: "NSDocumentsFolderUsageDescription",
  downloads: "NSDownloadsFolderUsageDescription",
  desktop: "NSDesktopFolderUsageDescription",
  network: "NSLocalNetworkUsageDescription",
  bluetooth: "NSBluetoothAlwaysUsageDescription",
  appleEvents: "NSAppleEventsUsageDescription",
};

/** Escape a string for use as text content in an XML element. */
function xmlEscape(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

/** Render a plistExtras value as plist XML. */
function renderPlistValue(v: string | number | boolean | string[]): string {
  if (typeof v === "boolean") return v ? "<true/>" : "<false/>";
  if (typeof v === "number") {
    return Number.isInteger(v)
      ? `<integer>${v}</integer>`
      : `<real>${v}</real>`;
  }
  if (Array.isArray(v)) {
    const items = v.map(s => `        <string>${xmlEscape(s)}</string>`).join("\n");
    return `<array>\n${items}\n    </array>`;
  }
  return `<string>${xmlEscape(v)}</string>`;
}

/** Read the optional plist extras file. Default location: build/macos/Info.plist.extra. */
async function loadPlistExtraFile(root: string, override?: string): Promise<string> {
  const file = override
    ? (path.isAbsolute(override) ? override : path.resolve(root, override))
    : path.join(root, "build", "macos", "Info.plist.extra");
  if (!existsSync(file)) return "";
  return await Bun.file(file).text();
}

/** Extract the keys defined in a partial plist (for override warnings). */
function extractPlistKeys(content: string): string[] {
  const matches = content.match(/<key>([^<]+)<\/key>/g) ?? [];
  return matches.map(m => m.replace(/<\/?key>/g, ""));
}

export async function generateInfoPlist(opts: PlistGenOptions): Promise<string> {
  const { root, appName, execName, config, iconResult } = opts;
  const macosConfig: MacOSConfig = config.macos ?? {};

  const identifier = config.identifier
    ?? `com.zapp.${appName.toLowerCase().replace(/[^a-z0-9]/g, "")}`;
  const version = config.version ?? "1.0.0";
  const minVersion = macosConfig.minimumSystemVersion ?? "12.0";
  const category = macosConfig.category ?? "";
  const copyright = macosConfig.copyright ?? "";
  const usageDescriptions = macosConfig.usageDescriptions ?? {};
  const plistExtras = macosConfig.plistExtras ?? {};

  // Track which keys we've emitted so we can detect user overrides.
  const cliEmittedKeys = new Set<string>();
  const lines: string[] = [];

  const addKey = (key: string, value: string) => {
    cliEmittedKeys.add(key);
    lines.push(`    <key>${key}</key>`);
    lines.push(`    ${value}`);
  };

  // Required core keys.
  addKey("CFBundleExecutable",            `<string>${xmlEscape(execName)}</string>`);
  addKey("CFBundleIdentifier",            `<string>${xmlEscape(identifier)}</string>`);
  addKey("CFBundleName",                  `<string>${xmlEscape(appName)}</string>`);
  addKey("CFBundleDisplayName",           `<string>${xmlEscape(appName)}</string>`);
  addKey("CFBundlePackageType",           `<string>APPL</string>`);
  addKey("CFBundleVersion",               `<string>${xmlEscape(version)}</string>`);
  addKey("CFBundleShortVersionString",    `<string>${xmlEscape(version)}</string>`);
  addKey("CFBundleInfoDictionaryVersion", `<string>6.0</string>`);
  addKey("LSMinimumSystemVersion",        `<string>${xmlEscape(minVersion)}</string>`);
  addKey("NSHighResolutionCapable",       `<true/>`);
  addKey("NSSupportsAutomaticGraphicsSwitching", `<true/>`);

  // Icon (asset catalog key + .icns fallback for older macOS).
  if (iconResult) {
    addKey(iconResult.plistKey, `<string>${xmlEscape(iconResult.plistValue)}</string>`);
    if (iconResult.plistKey === "CFBundleIconName") {
      addKey("CFBundleIconFile", `<string>AppIcon</string>`);
    }
  }

  // App Store category.
  if (category) {
    addKey("LSApplicationCategoryType", `<string>${xmlEscape(category)}</string>`);
  }

  // Copyright.
  if (copyright) {
    addKey("NSHumanReadableCopyright", `<string>${xmlEscape(copyright)}</string>`);
  }

  // Privacy usage descriptions.
  for (const [field, desc] of Object.entries(usageDescriptions)) {
    if (!desc) continue;
    const plistKey = USAGE_DESC_KEYS[field];
    if (!plistKey) continue;
    addKey(plistKey, `<string>${xmlEscape(desc as string)}</string>`);
  }

  // Single-instance enforcement (Launch Services rejects `open -n` etc.).
  if (config.singleInstance) {
    addKey("LSMultipleInstancesProhibited", `<true/>`);
  }

  // Deep link URL schemes.
  const schemes = config.deepLinkSchemes;
  if (schemes && schemes.length > 0) {
    const schemesXml = schemes
      .map(s => `            <string>${xmlEscape(s)}</string>`)
      .join("\n");
    cliEmittedKeys.add("CFBundleURLTypes");
    lines.push(`    <key>CFBundleURLTypes</key>`);
    lines.push(`    <array>`);
    lines.push(`        <dict>`);
    lines.push(`            <key>CFBundleURLName</key>`);
    lines.push(`            <string>${xmlEscape(identifier)}</string>`);
    lines.push(`            <key>CFBundleURLSchemes</key>`);
    lines.push(`            <array>`);
    lines.push(schemesXml);
    lines.push(`            </array>`);
    lines.push(`        </dict>`);
    lines.push(`    </array>`);
  }

  // plistExtras (typed map). Warn on overrides.
  for (const [key, value] of Object.entries(plistExtras)) {
    if (cliEmittedKeys.has(key)) {
      process.stdout.write(
        `[zapp] plistExtras: overriding CLI-derived key "${key}"\n`
      );
    }
    cliEmittedKeys.add(key);
    lines.push(`    <key>${xmlEscape(key)}</key>`);
    lines.push(`    ${renderPlistValue(value)}`);
  }

  // Raw plistFile (last — wins over everything).
  const extraContent = await loadPlistExtraFile(root, macosConfig.plistFile);
  if (extraContent.trim().length > 0) {
    const extraKeys = extractPlistKeys(extraContent);
    for (const key of extraKeys) {
      if (cliEmittedKeys.has(key)) {
        process.stdout.write(
          `[zapp] Info.plist.extra: overriding key "${key}"\n`
        );
      }
    }
    lines.push("    " + extraContent.trim().split("\n").join("\n    "));
  }

  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
${lines.join("\n")}
</dict>
</plist>`;
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
