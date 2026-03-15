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
  const frontendDir = path.join(projectDir, "frontend");
  const configDir = path.join(projectDir, "config");
  const darwinConfigDir = path.join(configDir, "darwin");
  const windowsConfigDir = path.join(configDir, "windows");

  console.log(`Scaffolding Zapp project in ${projectDir}...`);

  await mkdir(projectDir, { recursive: true });
  await mkdir(darwinConfigDir, { recursive: true });
  await mkdir(windowsConfigDir, { recursive: true });

  console.log(`Creating frontend with Vite template: ${template}...`);
  await spawnStreaming("bun", ["create", "vite", "frontend", "--template", template], { cwd: projectDir }).exited;

  const pkgPath = path.join(frontendDir, "package.json");
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
  pkgObj.devDependencies["@zapp/vite"] = "latest";
  pkgObj.dependencies = pkgObj.dependencies || {};
  pkgObj.dependencies["@zapp/runtime"] = "latest";

  await Bun.write(pkgPath, JSON.stringify(pkgObj, null, 2));

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
  await Bun.write(path.join(projectDir, "app.zc"), appZcContent);

  const buildZcContent = `// --- Baseline macOS Directives ---
//> macos: framework: Cocoa
//> macos: framework: WebKit
//> macos: framework: CoreFoundation
//> macos: framework: JavaScriptCore
//> macos: framework: Security
//> macos: link: -lcompression
//> macos: cflags: -fobjc-arc -x objective-c
// ---------------------------------

// --- Windows Directives (QuickJS default) ---
//> windows: cflags: -DUNICODE -D_UNICODE -DCINTERFACE -DCOBJMACROS
//> windows: cflags: -I../vendor/webview2/include
//> windows: cflags: -I../vendor/quickjs-ng
//> windows: link: -L../vendor/quickjs-ng/build
//> windows: link: -lqjs
//> windows: link: -lole32 -lshell32 -luuid -luser32 -lgdi32 -lcomctl32 -lshlwapi
//> windows: link: -lwinhttp -lbcrypt -ladvapi32 -lrpcrt4 -lcrypt32 -lversion
//> windows: define: _WIN32
//> windows: define: ZAPP_WORKER_ENGINE_QJS
// ---------------------------------

import "app.zc";

fn main() -> int {
    return run_app();
}
`;
  await Bun.write(path.join(projectDir, "build.zc"), buildZcContent);

  if (withBackend) {
    const rootPkgContent = JSON.stringify(
      {
        name,
        private: true,
        type: "module",
        dependencies: {
          "@zapp/runtime": "latest",
          "@zapp/backend": "latest",
        },
      },
      null,
      2,
    );
    await Bun.write(path.join(projectDir, "package.json"), rootPkgContent);

    const rootTsConfig = JSON.stringify(
      {
        compilerOptions: {
          target: "ES2022",
          module: "ESNext",
          moduleResolution: "bundler",
          strict: true,
          noEmit: true,
        },
        include: ["backend.ts"],
      },
      null,
      2,
    );
    await Bun.write(path.join(projectDir, "tsconfig.json"), rootTsConfig);

    const backendContent = `import { App } from "@zapp/backend";

// Your backend TypeScript runs in a privileged native context
// with direct access to native bridge, window management, and app lifecycle.
`;
    await Bun.write(path.join(projectDir, "backend.ts"), backendContent);
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

  console.log(`\nProject ${name} scaffolded successfully!`);
  console.log(`Next steps:`);
  if (withBackend) {
    console.log(`  cd ${name}`);
    console.log(`  bun install`);
    console.log(`  cd frontend`);
    console.log(`  bun install`);
    console.log(`  cd ..`);
  } else {
    console.log(`  cd ${name}/frontend`);
    console.log(`  bun install`);
    console.log(`  cd ..`);
  }
  console.log(`  zapp dev`);
};
