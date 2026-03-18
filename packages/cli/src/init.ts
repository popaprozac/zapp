import path from "node:path";
import { spawnStreaming } from "./common";
import { mkdir } from "node:fs/promises";

export const runInit = async ({
  root,
  name,
  template,
  withBackend,
}: {
  root: string;
  name: string;
  template: string;
  withBackend: boolean;
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

  const pkgPath = path.join(projectDir, "package.json");
  let pkgObj: any = {};
  try {
    const pkgFile = Bun.file(pkgPath);
    if (await pkgFile.exists()) {
      const pkgRaw = await pkgFile.text();
      pkgObj = JSON.parse(pkgRaw);
    }
  } catch (err) {
    console.error(`Warning: Could not read ${pkgPath}`);
  }

  pkgObj.devDependencies = pkgObj.devDependencies || {};
  pkgObj.devDependencies["@zapp/cli"] = "latest";
  pkgObj.devDependencies["@zapp/vite"] = "latest";
  pkgObj.dependencies = pkgObj.dependencies || {};
  pkgObj.dependencies["@zapp/runtime"] = "latest";
  if (withBackend) {
    pkgObj.dependencies["@zapp/backend"] = "latest";
  }

  await Bun.write(pkgPath, JSON.stringify(pkgObj, null, 2));

  const appZcContent = `import "app/app.zc";

fn run_app() -> int {
    let config = AppConfig{ 
        name: "${name}", 
        applicationShouldTerminateAfterLastWindowClosed: true,
        webContentInspectable: true,
        maxWorkers: 50,
    };
    let app = App::new(config);
    return app.run();
}
`;
  await Bun.write(path.join(zappDir, "app.zc"), appZcContent);

  const zappConfigContent = `import { defineConfig } from "@zapp/cli/config";

export default defineConfig({
  name: "${name}",
});
`;
  await Bun.write(path.join(zappDir, "zapp.config.ts"), zappConfigContent);

  const buildZcContent = `// Include paths and library paths are injected by the zapp CLI.

// --- macOS Directives ---
//> macos: framework: Cocoa
//> macos: framework: WebKit
//> macos: framework: CoreFoundation
//> macos: framework: JavaScriptCore
//> macos: framework: Security
//> macos: link: -lcompression
//> macos: cflags: -fobjc-arc -x objective-c
// To use QuickJS instead of JSC on macOS, uncomment:
//   //> macos: define: ZAPP_WORKER_ENGINE_QJS

// --- Windows Directives (QuickJS default) ---
//> windows: cflags: -DUNICODE -D_UNICODE -DCINTERFACE -DCOBJMACROS
//> windows: link: -lole32 -lshell32 -luuid -luser32 -lgdi32 -lcomctl32 -lshlwapi
//> windows: link: -lwinhttp -lbcrypt -ladvapi32 -lrpcrt4 -lcrypt32 -lversion
//> windows: define: ZAPP_WORKER_ENGINE_QJS

import "app.zc";

fn main() -> int {
    return run_app();
}
`;
  await Bun.write(path.join(zappDir, "build.zc"), buildZcContent);

  if (withBackend) {
    const backendContent = `import { App } from "@zapp/backend";

// Your backend TypeScript runs in a privileged native context
// with direct access to native bridge, window management, and app lifecycle.
`;
    await Bun.write(path.join(zappDir, "backend.ts"), backendContent);
  }

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
  await Bun.write(path.join(darwinConfigDir, "Info.plist"), plistContent);

  const manifestContent = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <assemblyIdentity
    type="win32"
    name="com.zapp.${name}"
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
`;
  await Bun.write(path.join(windowsConfigDir, "app.manifest"), manifestContent);

  console.log(`\nProject ${name} scaffolded successfully!`);
  console.log(`Next steps:`);
  console.log(`  cd ${name}`);
  console.log(`  bun install`);
  console.log(`  zapp dev`);
};
