import { mkdir, copyFile, chmod } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { existsSync } from "node:fs";
import { runCmd } from "./common";
import type { ResolvedZappConfig } from "./config";
import { generateIcns, compileIconAsset } from "./icons";

export const runPackage = async ({ root, nativeOut, config }: { root: string; nativeOut: string; config: ResolvedZappConfig }) => {
  if (process.platform === "darwin") {
    await packageMacOS({ root, nativeOut, config });
  } else if (process.platform === "win32") {
    console.log("[zapp] Windows packaging: the binary is ready at " + nativeOut);
    console.log("[zapp] Icon embedding happens during 'zapp build' (see build.ts).");
    console.log("[zapp] Installer generation (NSIS/MSIX) is not yet implemented.");
  } else {
    console.error("[zapp] Packaging is not yet supported on this platform.");
  }
};

async function packageMacOS({ root, nativeOut, config }: { root: string; nativeOut: string; config: ResolvedZappConfig }) {
  const appName = config.name;
  const appBundleName = `${appName}.app`;
  const binDir = path.join(root, "bin");
  await mkdir(binDir, { recursive: true });
  const appBundlePath = path.join(binDir, appBundleName);

  process.stdout.write(`[zapp] packaging ${appName} → ${appBundleName}\n`);

  const contentsDir = path.join(appBundlePath, "Contents");
  const macosDir = path.join(contentsDir, "MacOS");
  const resourcesDir = path.join(contentsDir, "Resources");

  await mkdir(macosDir, { recursive: true });
  await mkdir(resourcesDir, { recursive: true });

  // 1. Copy the executable
  const execPath = path.resolve(root, nativeOut);
  if (!existsSync(execPath)) {
    console.error(`[zapp] binary not found at ${execPath}. Run 'zapp build' first.`);
    return;
  }

  const destExecPath = path.join(macosDir, appName);
  await copyFile(execPath, destExecPath);
  await chmod(destExecPath, 0o755);

  // 2. Icons
  let hasIcon = false;
  let hasLiquidGlass = false;

  // Standard icon: PNG → .icns
  if (config.icon) {
    const iconSource = path.resolve(root, config.icon);
    const icnsPath = await generateIcns(iconSource, resourcesDir);
    if (icnsPath) {
      hasIcon = true;
      process.stdout.write(`[zapp] generated AppIcon.icns\n`);
    }
  }

  // Liquid glass icon: .icon folder → Assets.car
  if (config.macos?.iconLayers) {
    const iconFolder = path.resolve(root, config.macos.iconLayers);
    const carPath = await compileIconAsset(iconFolder, resourcesDir);
    if (carPath) {
      hasLiquidGlass = true;
      process.stdout.write(`[zapp] compiled liquid glass icon → Assets.car\n`);
    }
  }

  // 3. Generate Info.plist
  const configPlistPath = path.join(root, "config", "darwin", "Info.plist");
  let plistContent = "";

  if (existsSync(configPlistPath)) {
    plistContent = await Bun.file(configPlistPath).text();
    // Inject deep link URL scheme if configured
    if (config.deepLink?.scheme && !plistContent.includes("CFBundleURLTypes")) {
      plistContent = plistContent.replace(
        "</dict>",
        `    <key>CFBundleURLTypes</key>\n    <array>\n        <dict>\n            <key>CFBundleURLName</key>\n            <string>${config.identifier}</string>\n            <key>CFBundleURLSchemes</key>\n            <array>\n                <string>${config.deepLink.scheme}</string>\n            </array>\n        </dict>\n    </array>\n</dict>`
      );
    }
    // Inject icon keys if icon was generated and plist doesn't have them
    if (hasIcon && !plistContent.includes("CFBundleIconFile")) {
      plistContent = plistContent.replace(
        "</dict>",
        `    <key>CFBundleIconFile</key>\n    <string>AppIcon</string>\n    <key>CFBundleIconName</key>\n    <string>AppIcon</string>\n</dict>`
      );
    }
    process.stdout.write(`[zapp] using custom Info.plist\n`);
  } else {
    const minVersion = config.macos?.minimumSystemVersion ?? "13.0";
    const category = config.macos?.category ?? "";
    const copyright = config.author ? `Copyright © ${new Date().getFullYear()} ${config.author}` : "";

    let extraKeys = "";
    if (hasIcon || hasLiquidGlass) {
      extraKeys += `    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>\n`;
    }
    if (category) {
      extraKeys += `    <key>LSApplicationCategoryType</key>
    <string>${category}</string>\n`;
    }
    if (copyright) {
      extraKeys += `    <key>NSHumanReadableCopyright</key>
    <string>${copyright}</string>\n`;
    }
    if (config.deepLink?.scheme) {
      extraKeys += `    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>${config.identifier}</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>${config.deepLink.scheme}</string>
            </array>
        </dict>
    </array>\n`;
    }

    plistContent = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${appName}</string>
    <key>CFBundleExecutable</key>
    <string>${appName}</string>
    <key>CFBundleIdentifier</key>
    <string>${config.identifier}</string>
    <key>CFBundleVersion</key>
    <string>${config.version}</string>
    <key>CFBundleShortVersionString</key>
    <string>${config.version}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>${minVersion}</string>
    <key>NSHighResolutionCapable</key>
    <true/>
${extraKeys}</dict>
</plist>`;
  }

  // Ensure CFBundleExecutable is set correctly
  if (!plistContent.includes("<key>CFBundleExecutable</key>")) {
    plistContent = plistContent.replace(
      "<dict>",
      `<dict>\n    <key>CFBundleExecutable</key>\n    <string>${appName}</string>`
    );
  }

  await Bun.write(path.join(contentsDir, "Info.plist"), plistContent);

  // 4. Ad-hoc codesign
  try {
    await runCmd("codesign", ["--force", "--deep", "--sign", "-", appBundlePath]);
    process.stdout.write(`[zapp] codesigned (ad-hoc)\n`);
  } catch {
    console.warn("[zapp] codesign failed (non-fatal)");
  }

  process.stdout.write(`[zapp] packaged → ${appBundlePath}\n`);
}
