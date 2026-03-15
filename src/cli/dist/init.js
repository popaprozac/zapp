import fs from "node:fs/promises";
import path from "node:path";
import { spawnStreaming } from "./common.js";
export const runInit = async ({ root, name, template }) => {
    const projectDir = path.resolve(root, name);
    const frontendDir = path.join(projectDir, "frontend");
    const configDir = path.join(projectDir, "config");
    const darwinConfigDir = path.join(configDir, "darwin");
    const windowsConfigDir = path.join(configDir, "windows");
    console.log(`Scaffolding Zapp project in ${projectDir}...`);
    // Create directories
    await fs.mkdir(projectDir, { recursive: true });
    await fs.mkdir(darwinConfigDir, { recursive: true });
    await fs.mkdir(windowsConfigDir, { recursive: true });
    // 1. Scaffold frontend using create-vite
    console.log(`Creating frontend with Vite template: ${template}...`);
    await spawnStreaming("bun", ["create", "vite", "frontend", "--template", template], { cwd: projectDir });
    // Read existing package.json from generated frontend to inject dependencies
    const pkgPath = path.join(frontendDir, "package.json");
    let pkgObj = {};
    try {
        const pkgRaw = await fs.readFile(pkgPath, "utf8");
        pkgObj = JSON.parse(pkgRaw);
    }
    catch (err) {
        console.error(`Warning: Could not read ${pkgPath}`);
    }
    // Inject Zapp dependencies into frontend/package.json
    pkgObj.devDependencies = pkgObj.devDependencies || {};
    pkgObj.devDependencies["@zapp/vite"] = "latest";
    pkgObj.dependencies = pkgObj.dependencies || {};
    pkgObj.dependencies["@zapp/runtime"] = "latest";
    await fs.writeFile(pkgPath, JSON.stringify(pkgObj, null, 2));
    // 2. Generate app.zc
    const appZcContent = `import "zapp/app/app.zc";

fn run_app() -> int {
    let config = AppConfig{ 
        name: "${name}", 
        applicationShouldTerminateAfterLastWindowClosed: true,
        webContentInspectable: true,
        maxWorkers: 50,
    };
    let app = App::new(config);
    app.window.create(&WindowOptions{
        title: "${name}",
        width: 1200,
        height: 800,
        x: 80,
        y: 80,
        visible: true,
        titleBarStyle: WINDOW_TITLEBAR_STYLE_DEFAULT,
    });
    return app.run();
}
`;
    await fs.writeFile(path.join(projectDir, "app.zc"), appZcContent);
    // 3. Generate build.zc
    const buildZcContent = `// --- Baseline macOS Directives ---
//> macos: framework: Cocoa
//> macos: framework: WebKit
//> macos: framework: CoreFoundation
//> macos: framework: JavaScriptCore
//> macos: framework: Security
//> macos: cflags: -fobjc-arc -x objective-c
// ---------------------------------

import "app.zc";

fn main() -> int {
    return run_app();
}
`;
    await fs.writeFile(path.join(projectDir, "build.zc"), buildZcContent);
    // 4. Generate Info.plist for Darwin
    const plistContent = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${name}</string>
    <key>CFBundleIdentifier</key>
    <string>com.zapp.${name}</string>
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
</plist>
`;
    await fs.writeFile(path.join(darwinConfigDir, "Info.plist"), plistContent);
    console.log(`\nProject ${name} scaffolded successfully!`);
    console.log(`Next steps:`);
    console.log(`  cd ${name}/frontend`);
    console.log(`  bun install`);
    console.log(`  cd ..`);
    console.log(`  zapp dev`);
};
