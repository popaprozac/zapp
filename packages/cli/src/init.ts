import path from "node:path";
import { spawnStreaming } from "./common";
import { mkdir } from "node:fs/promises";

export const runInit = async ({
  root,
  name,
  template,
}: {
  root: string;
  name: string;
  template: string;
}) => {
  const projectDir = path.resolve(root, name);
  const zappDir = path.join(projectDir, "zapp");
  const configDir = path.join(projectDir, "config");
  const darwinConfigDir = path.join(configDir, "darwin");
  const windowsConfigDir = path.join(configDir, "windows");

  console.log(`Scaffolding Zapp project in ${projectDir}...`);

  await mkdir(projectDir, { recursive: true });

  console.log(`Creating Vite project with template: ${template}...`);
  await spawnStreaming("bun", ["create", "vite", ".", "--template", template], { cwd: projectDir }).exited;

  await mkdir(zappDir, { recursive: true });
  await mkdir(darwinConfigDir, { recursive: true });
  await mkdir(windowsConfigDir, { recursive: true });

  // Add Zapp dependencies to package.json
  const pkgPath = path.join(projectDir, "package.json");
  let pkgObj: Record<string, unknown> = {};
  try {
    const pkgFile = Bun.file(pkgPath);
    if (await pkgFile.exists()) {
      pkgObj = JSON.parse(await pkgFile.text());
    }
  } catch {
    console.error(`Warning: Could not read ${pkgPath}`);
  }

  const devDeps = (pkgObj.devDependencies ?? {}) as Record<string, string>;
  devDeps["@zappdev/cli"] = "latest";
  devDeps["@zappdev/vite"] = "latest";
  pkgObj.devDependencies = devDeps;

  const deps = (pkgObj.dependencies ?? {}) as Record<string, string>;
  deps["@zappdev/runtime"] = "latest";
  pkgObj.dependencies = deps;

  await Bun.write(pkgPath, JSON.stringify(pkgObj, null, 2));

  // --- Zen-C entry point ---
  await Bun.write(path.join(zappDir, "app.zc"), `import "app/app.zc";

fn on_ready(id: int, handle: void*) -> void {
    println "Window ready!";
    Window{id: id, handle: handle}.show();
}

fn run_app() -> int {
    let config = AppConfig{
        name: "${name}",
        applicationShouldTerminateAfterLastWindowClosed: true,
        webContentInspectable: -1, // -1 = inherit from build (dev=on, prod=off)
        maxWorkers: 0,
        qjsStackSize: 0,
    };
    let app = App::new(config);

    let opts = window_options_default("${name}");
    opts.visible = false;
    let win = app.window.create(&opts);
    win.on_ready(on_ready);

    return app.run();
}
`);

  // --- Zapp config ---
  await Bun.write(path.join(zappDir, "zapp.config.ts"), `import { defineConfig } from "@zappdev/cli/config";

export default defineConfig({
  name: "${name}",
  identifier: "com.zapp.${name.toLowerCase().replace(/[^a-z0-9]/g, "")}",
  version: "0.1.0",
});
`);

  // --- Build entry ---
  await Bun.write(path.join(zappDir, "build.zc"), `// --- Platform Tags ---
//> macos: define: apple
//> windows: define: windows

// --- macOS Directives ---
//> macos: framework: Cocoa
//> macos: framework: WebKit
//> macos: framework: CoreFoundation
//> macos: framework: JavaScriptCore
//> macos: framework: Security
//> macos: link: -lcompression
//> macos: cflags: -fobjc-arc -x objective-c
// To use QuickJS instead of JSC on macOS, uncomment:
// //> macos: define: ZAPP_WORKER_ENGINE_QJS

// --- Windows Directives ---
//> windows: cflags: -DUNICODE -D_UNICODE -DCINTERFACE -DCOBJMACROS
//> windows: link: -lole32 -lshell32 -luuid -luser32 -lgdi32 -lcomctl32 -lcomdlg32 -lshlwapi
//> windows: link: -lwinhttp -lbcrypt -ladvapi32 -lrpcrt4 -lcrypt32 -lversion
// Uncomment to enable Zapp Workers on Windows (adds ~760 KB):
// //> windows: define: ZAPP_WORKER_ENGINE_QJS

import "app.zc";

fn main() -> int {
    return run_app();
}
`);

  // --- macOS Info.plist ---
  await Bun.write(path.join(darwinConfigDir, "Info.plist"), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${name}</string>
    <key>CFBundleIdentifier</key>
    <string>com.zapp.${name.toLowerCase().replace(/[^a-z0-9]/g, "")}</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
`);

  // --- Windows app.manifest ---
  await Bun.write(path.join(windowsConfigDir, "app.manifest"), `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <assemblyIdentity
    type="win32"
    name="com.zapp.${name.toLowerCase().replace(/[^a-z0-9]/g, "")}"
    version="1.0.0.0"
  />
  <description>${name}</description>

  <!-- Enable visual styles (modern controls) -->
  <dependency>
    <dependentAssembly>
      <assemblyIdentity
        type="win32"
        name="Microsoft.Windows.Common-Controls"
        version="6.0.0.0"
        processorArchitecture="*"
        publicKeyToken="6595b64144ccf1df"
        language="*"
      />
    </dependentAssembly>
  </dependency>

  <!-- High-DPI awareness (Per-Monitor V2) -->
  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    <windowsSettings>
      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2,PerMonitor</dpiAwareness>
      <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">True/PM</dpiAware>
    </windowsSettings>
  </application>

  <!-- Declare supported OS versions -->
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application>
      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}" /> <!-- Windows 10/11 -->
      <supportedOS Id="{1f676c76-80e1-4239-95bb-83d0f6d0da78}" /> <!-- Windows 8.1 -->
    </application>
  </compatibility>
</assembly>
`);

  console.log(`\nProject ${name} scaffolded successfully!`);
  console.log(`Next steps:`);
  console.log(`  cd ${name}`);
  console.log(`  bun install`);
  console.log(`  zapp dev`);
};
