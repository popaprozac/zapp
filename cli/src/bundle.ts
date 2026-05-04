// Create a minimal .app bundle for dev mode.
// Enables: notifications, proper dock icon, app name, about panel.
// Ad-hoc signed for local development.

import path from "node:path";
import { mkdir, unlink, rm, cp, stat } from "node:fs/promises";
import { existsSync } from "node:fs";
import type { ResolvedConfig } from "./config";
import { processIcon } from "./icon";
import { resolveAppIconPath } from "./paths";
import { resolveEntitlements } from "./entitlements";

export async function createDevBundle(root: string, binaryPath: string, config: ResolvedConfig): Promise<string> {
  const appName = config.name.replace(/[^a-zA-Z0-9 _-]/g, "");
  const binDir = path.join(root, "bin");
  const appDir = path.join(binDir, `${appName}.app`);
  const contentsDir = path.join(appDir, "Contents");
  const macOSDir = path.join(contentsDir, "MacOS");
  const execName = path.basename(binaryPath);

  await mkdir(macOSDir, { recursive: true });

  // Symlink or copy the binary into the .app bundle
  const execPath = path.join(macOSDir, execName);
  try { await unlink(execPath); } catch {}
  // Copy the binary into the .app bundle (symlinks break mainBundle resolution)
  await Bun.write(execPath, Bun.file(binaryPath));
  // Make executable
  const { chmod } = await import("node:fs/promises");
  await chmod(execPath, 0o755);

  // Process icon — user-configured or framework default
  const resourcesDir = path.join(contentsDir, "Resources");
  await mkdir(resourcesDir, { recursive: true });
  let iconPlistEntry = "";

  // Resolve icon source: macos.icon → build/macos/icon.* → framework default.
  // Same priority as production package (cli/src/package.ts).
  const iconSrc = resolveAppIconPath(root, config.macos?.icon);

  if (iconSrc) {
      const tempDir = path.join(root, ".zapp", "icon-tmp");
      await mkdir(tempDir, { recursive: true });
      try {
        const result = await processIcon(iconSrc, tempDir);
        for (const file of result.files) {
          const destPath = path.join(resourcesDir, file.dest);
          const srcStat = await stat(file.src);
          if (srcStat.isDirectory()) {
            await cp(file.src, destPath, { recursive: true });
          } else {
            await Bun.write(destPath, Bun.file(file.src));
          }
        }
        iconPlistEntry = `
    <key>${result.plistKey}</key>
    <string>${result.plistValue}</string>`;
        // Also add CFBundleIconFile for older macOS fallback
        if (result.plistKey === "CFBundleIconName") {
          iconPlistEntry += `
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>`;
        }
      } finally {
        await rm(tempDir, { recursive: true, force: true });
      }
  }

  // Generate Info.plist
  // Dev bundles use a .dev suffix to avoid conflicting with release bundles
  // (e.g. notification routing uses bundle ID to find the right app)
  const identifier = (config.identifier ?? `com.zapp.${appName.toLowerCase().replace(/[^a-z0-9]/g, "")}`) + ".dev";
  const version = config.version ?? "0.1.0";

  const plist = `<?xml version="1.0" encoding="UTF-8"?>
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
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>${iconPlistEntry}${buildDeepLinkPlist(config)}${buildSingleInstancePlist(config)}
</dict>
</plist>`;

  function buildSingleInstancePlist(cfg: ResolvedConfig): string {
    if (!cfg.singleInstance) return "";
    return `
    <key>LSMultipleInstancesProhibited</key>
    <true/>`;
  }

  function buildDeepLinkPlist(cfg: ResolvedConfig): string {
    const schemes = cfg.deepLinkSchemes;
    if (!schemes || schemes.length === 0) return "";
    const id = cfg.identifier ?? `com.zapp.${appName.toLowerCase().replace(/[^a-z0-9]/g, "")}`;
    const schemesXml = schemes.map(s => `            <string>${s}</string>`).join("\n");
    return `
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>${id}</string>
            <key>CFBundleURLSchemes</key>
            <array>
${schemesXml}
            </array>
        </dict>
    </array>`;
  }

  await Bun.write(path.join(contentsDir, "Info.plist"), plist);

  // Ad-hoc code sign (with entitlements if configured — some APIs read them
  // even under ad-hoc, and keeping dev consistent with `zapp package` makes
  // sign-path differences surface earlier).
  const entitlements = await resolveEntitlements(root, config);
  const codesignArgs = ["codesign", "--force", "-s", "-"];
  if (entitlements.used) {
    codesignArgs.push("--entitlements", entitlements.path);
  }
  codesignArgs.push(appDir);

  const signProc = Bun.spawn(codesignArgs, {
    stdout: "pipe",
    stderr: "pipe",
  });
  await signProc.exited;

  return appDir;
}

/** Get the launch path for a .app bundle (the executable inside Contents/MacOS/) */
export function getAppLaunchCommand(appDir: string): string[] {
  // Use `open` to launch the .app bundle properly (gets dock icon, app name, etc.)
  return ["open", "-a", appDir, "--args"];
}
