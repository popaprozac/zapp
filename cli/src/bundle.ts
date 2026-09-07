// Publish complete, signed bundles; never merge into an older .app directory.
import path from "node:path";
import { chmod, copyFile, cp, mkdir, mkdtemp, rename, rm, stat } from "node:fs/promises";
import type { ResolvedConfig } from "./config";
import { processIcon } from "./icon";
import { resolveAppIconPath } from "./paths";
import { resolveEntitlements, xmlEscape } from "./entitlements";
import { runBoundedCommand } from "./bounded-process";

const launchServices = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";

// Internal build control, not application configuration or runtime API.
export interface DevBundleOptions { smoke?: boolean; }

export async function createDevBundle(
  root: string,
  binaryPath: string,
  config: ResolvedConfig,
  options: DevBundleOptions = {},
  runCommand: typeof runBoundedCommand = runBoundedCommand,
): Promise<string> {
  const appName = config.name.replace(/[^a-zA-Z0-9 _-]/g, "").trim() || "Application";
  const binDir = options.smoke
    ? path.join(root, ".zapp", "smoke", "bin") : path.join(root, "bin");
  const appDir = path.join(binDir, appName + ".app");
  await mkdir(binDir, { recursive: true });
  const staging = await mkdtemp(path.join(binDir, "." + appName + "-staging-"));
  const candidate = path.join(staging, appName + ".app");
  const previous = path.join(staging, "previous.app");
  let savedPrevious = false;
  let published = false;
  let preserveStaging = false;

  async function checked(command: string[], label: string): Promise<void> {
    const result = await runCommand(command, { cwd: root, timeoutMs: 15000 });
    if (result.status !== 0 || result.timedOut) {
      throw new Error("[zapp] " + label + (result.timedOut ? " timed out" : " failed (" + result.status + ")")
        + ": " + (result.stderr.trim() || result.stdout.trim()));
    }
  }

  try {
    const contentsDir = path.join(candidate, "Contents");
    const macOSDir = path.join(contentsDir, "MacOS");
    const resourcesDir = path.join(contentsDir, "Resources");
    const execName = path.basename(binaryPath);
    await mkdir(macOSDir, { recursive: true });
    await mkdir(resourcesDir, { recursive: true });
    // Copy, not symlink: NSBundle must resolve to this complete bundle.
    const execPath = path.join(macOSDir, execName);
    await copyFile(binaryPath, execPath);
    await chmod(execPath, 0o755);

    let iconPlistEntry = "";
    const iconSrc = resolveAppIconPath(root, config.macos?.icon);
    if (iconSrc) {
      const iconTemp = path.join(staging, "icon");
      await mkdir(iconTemp, { recursive: true });
      const result = await processIcon(iconSrc, iconTemp);
      for (const file of result.files) {
        const destination = path.join(resourcesDir, file.dest);
        if ((await stat(file.src)).isDirectory()) {
          await cp(file.src, destination, { recursive: true });
        } else {
          await copyFile(file.src, destination);
        }
      }
      iconPlistEntry = "\n    <key>" + xmlEscape(result.plistKey) + "</key>\n    <string>" + xmlEscape(result.plistValue) + "</string>";
      if (result.plistKey === "CFBundleIconName") {
        iconPlistEntry += "\n    <key>CFBundleIconFile</key>\n    <string>AppIcon</string>";
      }
    }

    const applicationId = config.identifier ?? "com.zapp." + appName.toLowerCase().replace(/[^a-z0-9]/g, "");
    const identifier = applicationId + (options.smoke ? ".smoke.dev" : ".dev");
    // Smoke executables are addressed directly by the test harness; they must
    // not advertise themselves as handlers for the interactive app's schemes.
    const schemes = options.smoke ? [] : config.deepLinkSchemes ?? [];
    const deepLinks = schemes.length === 0 ? "" : [
      "    <key>CFBundleURLTypes</key>", "    <array>", "        <dict>",
      "            <key>CFBundleURLName</key>",
      "            <string>" + xmlEscape(applicationId) + "</string>",
      "            <key>CFBundleURLSchemes</key>", "            <array>",
      ...schemes.map(scheme => "                <string>" + xmlEscape(scheme) + "</string>"),
      "            </array>", "        </dict>", "    </array>",
    ].join("\n");
    const plist = [
      '<?xml version="1.0" encoding="UTF-8"?>',
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
      '<plist version="1.0">', "<dict>",
      "    <key>CFBundleExecutable</key>", "    <string>" + xmlEscape(execName) + "</string>",
      "    <key>CFBundleIdentifier</key>", "    <string>" + xmlEscape(identifier) + "</string>",
      "    <key>CFBundleName</key>", "    <string>" + xmlEscape(appName) + "</string>",
      "    <key>CFBundleDisplayName</key>", "    <string>" + xmlEscape(appName) + "</string>",
      "    <key>CFBundlePackageType</key>", "    <string>APPL</string>",
      "    <key>CFBundleVersion</key>", "    <string>" + xmlEscape(config.version ?? "0.1.0") + "</string>",
      "    <key>CFBundleShortVersionString</key>", "    <string>" + xmlEscape(config.version ?? "0.1.0") + "</string>",
      "    <key>CFBundleInfoDictionaryVersion</key>", "    <string>6.0</string>",
      "    <key>NSHighResolutionCapable</key>", "    <true/>",
      "    <key>NSSupportsAutomaticGraphicsSwitching</key>", "    <true/>",
      iconPlistEntry, deepLinks,
      ...(config.singleInstance ? ["    <key>LSMultipleInstancesProhibited</key>", "    <true/>"] : []),
      "</dict>", "</plist>", "",
    ].join("\n");
    await Bun.write(path.join(contentsDir, "Info.plist"), plist);

    const entitlements = await resolveEntitlements(root, config);
    await checked([
      "/usr/bin/codesign", "--force", "-s", "-",
      ...(entitlements.used ? ["--entitlements", entitlements.path] : []),
      candidate,
    ], "development bundle signing");
    await checked(["/usr/bin/codesign", "--verify", "--strict", candidate], "development bundle verification");

    try {
      await rename(appDir, previous);
      savedPrevious = true;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
    await rename(candidate, appDir);
    published = true;
    if (!options.smoke) {
      // Refresh only this bundle, at its final path. Never reset the user's
      // LaunchServices database or overwrite default scheme preferences.
      await checked([launchServices, "-f", appDir], "development bundle registration");
    }
    return appDir;
  } catch (error) {
    // Signing errors leave the previous app untouched. Publication failures
    // restore it; if restoration itself fails, keep its recovery directory.
    try {
      if (published) await rm(appDir, { recursive: true, force: true });
      if (savedPrevious) {
        await rename(previous, appDir);
        savedPrevious = false;
        if (!options.smoke) {
          await checked([launchServices, "-f", appDir], "previous bundle registration");
        }
      }
    } catch (restoreError) {
      preserveStaging = savedPrevious;
      throw new AggregateError([error, restoreError],
        "[zapp] bundle update failed; recovery path: " + (savedPrevious ? previous : appDir));
    }
    throw error;
  } finally {
    if (!preserveStaging) await rm(staging, { recursive: true, force: true });
  }
}

/** Open an already-published bundle through LaunchServices. */
export function getAppLaunchCommand(appDir: string): string[] {
  return ["open", "-a", appDir, "--args"];
}
