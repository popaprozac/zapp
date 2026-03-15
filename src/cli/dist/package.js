import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { runCmd } from "./common.js";
export const runPackage = async ({ root, nativeOut }) => {
    if (process.platform !== "darwin") {
        console.error("The package command is currently only supported on macOS.");
        return;
    }
    // Find app name from root directory or config
    const appName = path.basename(root) || "ZappApp";
    const appBundleName = `${appName}.app`;
    const appBundlePath = path.join(root, appBundleName);
    console.log(`Packaging ${appName} to ${appBundleName}...`);
    const contentsDir = path.join(appBundlePath, "Contents");
    const macosDir = path.join(contentsDir, "MacOS");
    const resourcesDir = path.join(contentsDir, "Resources");
    await fs.mkdir(macosDir, { recursive: true });
    await fs.mkdir(resourcesDir, { recursive: true });
    // 1. Copy the executable
    const execPath = path.resolve(root, nativeOut);
    try {
        await fs.access(execPath);
    }
    catch {
        console.error(`Error: Native binary not found at ${execPath}. Run 'zapp build' first.`);
        return;
    }
    const destExecPath = path.join(macosDir, appName);
    await fs.copyFile(execPath, destExecPath);
    await fs.chmod(destExecPath, 0o755);
    // 2. Generate or copy Info.plist
    const configPlistPath = path.join(root, "config", "darwin", "Info.plist");
    let plistContent = "";
    try {
        plistContent = await fs.readFile(configPlistPath, "utf8");
        console.log(`Using Info.plist from ${configPlistPath}`);
    }
    catch {
        console.log(`No Info.plist found at ${configPlistPath}, generating default...`);
        plistContent = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${appName}</string>
    <key>CFBundleExecutable</key>
    <string>${appName}</string>
    <key>CFBundleIdentifier</key>
    <string>com.zapp.${appName}</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>10.13</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>`;
    }
    // Ensure CFBundleExecutable is set correctly if it was missing or mismatched
    if (!plistContent.includes("<key>CFBundleExecutable</key>")) {
        plistContent = plistContent.replace("<dict>", `<dict>\n    <key>CFBundleExecutable</key>\n    <string>${appName}</string>`);
    }
    await fs.writeFile(path.join(contentsDir, "Info.plist"), plistContent);
    // 3. Simple ad-hoc codesign
    try {
        console.log(`Codesigning ${appBundlePath}...`);
        await runCmd("codesign", ["--force", "--deep", "--sign", "-", appBundlePath]);
    }
    catch (err) {
        console.error(`Warning: Failed to codesign ${appBundlePath}:`, err);
    }
    console.log(`Successfully packaged to ${appBundlePath}`);
};
