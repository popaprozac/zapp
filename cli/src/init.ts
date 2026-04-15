// Scaffold a new Zapp project.
// Wraps `bun create vite` then adds zapp/ native code + config.
// Does NOT modify the Vite template files — users add Zapp imports themselves.

import path from "node:path";
import { mkdir } from "node:fs/promises";
import { existsSync } from "node:fs";

interface InitOptions {
  name: string;
  template: string;
  root: string;
}

export async function runInit(opts: InitOptions) {
  const { name, template, root } = opts;
  const projectDir = path.join(root, name);

  if (existsSync(projectDir)) {
    process.stderr.write(`[zapp] directory '${name}' already exists\n`);
    process.exit(1);
  }

  // 1. Scaffold Vite project files (no install, no dev server).
  // create-vite has an --immediate flag that auto-installs + starts the dev
  // server, and an interactive prompt that does the same if confirmed.
  // --no-interactive skips the prompt and defaults to no install.
  process.stdout.write(`[zapp] creating ${name} with template ${template}...\n`);
  const viteProc = Bun.spawn(
    ["bunx", "create-vite@latest", name, "--template", template, "--no-interactive"],
    { cwd: root, stdout: "inherit", stderr: "inherit" },
  );
  if ((await viteProc.exited) !== 0) {
    process.stderr.write("[zapp] vite scaffold failed\n");
    process.exit(1);
  }

  // 2. Add zapp/ native code
  const zappDir = path.join(projectDir, "zapp");
  await mkdir(zappDir, { recursive: true });

  await Bun.write(path.join(zappDir, "app.zc"), `import "app/app.zc";

fn greet(_app: App*, _args: JsonValue*) -> string {
    return "Hello from Zapp!";
}

fn on_ready(_id: int, _handle: void*) -> void {
    Window{id: _id, handle: _handle}.show();
}

fn run_app() -> int {
    let config = AppConfig{
        name: "${name}",
        applicationShouldTerminateAfterLastWindowClosed: true,
        webContentInspectable: Zapp::inspectable_auto(),
        maxWorkers: 0,
        qjsStackSize: 0,
    };
    let app = App::new(config);
    app.service.add("greet", greet);

    let opts = WindowOptions::create("${name}");
    opts.visible = false;
    let win = app.window.create(&opts);
    win.on_ready(on_ready);

    return app.run();
}
`);

  await Bun.write(path.join(zappDir, "build.zc"), `// Build directives — platform tags and framework linking.
// .m file compilation is handled by the zapp CLI.

//> macos: define: apple
//> windows: define: windows

// --- Worker engine (choose one) ---
// JSC — macOS only, ~450 KB. Workers run JavaScript via JavaScriptCore.
// Comment it out and uncomment TXIKI below to switch engines.
//> macos: define: ZAPP_WORKER_ENGINE_JSC

// txiki.js — cross-platform, ~6.5 MB. Adds fetch, WebSocket, timers,
// and other web APIs to workers. CLI downloads and builds it on first
// use (takes ~60s the first time). To switch, comment out the JSC line
// above and uncomment:
// //> macos: define: ZAPP_WORKER_ENGINE_TXIKI

//> macos: framework: Cocoa
//> macos: framework: WebKit
//> macos: framework: CoreFoundation
//> macos: framework: JavaScriptCore
//> macos: framework: Security
//> macos: framework: UserNotifications
//> macos: link: -lcompression
//> macos: cflags: -fobjc-arc -x objective-c

//> windows: cflags: -DUNICODE -D_UNICODE -DCINTERFACE -DCOBJMACROS
//> windows: link: -lole32 -lshell32 -luuid -luser32 -lgdi32 -lcomctl32 -lcomdlg32 -lshlwapi
//> windows: link: -lwinhttp -lbcrypt -ladvapi32 -lrpcrt4 -lcrypt32 -lversion

import "app.zc";

fn main() -> int {
    return run_app();
}
`);

  // 3. Add zapp.config.ts — typed via defineConfig for autocomplete
  const identifier = `com.zapp.${name.toLowerCase().replace(/[^a-z0-9]/g, "")}`;
  await Bun.write(path.join(projectDir, "zapp.config.ts"), `import { defineConfig } from "@zappdev/cli/config";

export default defineConfig({
  name: "${name}",
  identifier: "${identifier}",
  version: "0.1.0",
  // Add headless TypeScript workers that start when the app boots.
  // Keys are worker IDs (used for termination); values are source paths.
  //
  //   headless: {
  //     db: "src/workers/db.ts",
  //   },
});
`);

  // 4. Update package.json — add deps and scripts
  const pkgPath = path.join(projectDir, "package.json");
  const pkgObj = JSON.parse(await Bun.file(pkgPath).text());

  pkgObj.scripts = {
    ...pkgObj.scripts,
    "dev": "zapp dev",
    "build": "zapp build",
    "package": "zapp package",
    "generate": "zapp generate",
  };

  pkgObj.dependencies = {
    ...(pkgObj.dependencies ?? {}),
    "@zappdev/runtime": "^0.6.0-alpha.0",
  };
  pkgObj.devDependencies = {
    ...(pkgObj.devDependencies ?? {}),
    "@zappdev/cli": "^0.6.0-alpha.0",
    "@zappdev/vite": "^0.6.0-alpha.0",
  };

  await Bun.write(pkgPath, JSON.stringify(pkgObj, null, 2));

  // 5. Inject zappWorkers() into the template's vite.config.ts
  // Templates like svelte-ts ship their own vite.config.ts with framework
  // plugins (e.g. svelte()). We must preserve those and append ours.
  const viteConfigPath = path.join(projectDir, "vite.config.ts");
  // Also check .js — some templates use vite.config.js
  const viteConfigJsPath = path.join(projectDir, "vite.config.js");
  const configPath = existsSync(viteConfigPath) ? viteConfigPath
    : existsSync(viteConfigJsPath) ? viteConfigJsPath
    : null;

  if (configPath) {
    let viteConfig = await Bun.file(configPath).text();

    // Add our imports at the top (after existing imports)
    const importLines = [
      `import { zappWorkers } from "@zappdev/vite";`,
      `import zappConfig from "./zapp.config";`,
    ];
    for (const importLine of importLines) {
      const pkg = importLine.match(/from ["'](.+?)["']/)?.[1] ?? "";
      if (viteConfig.includes(pkg)) continue;
      const lastImportIdx = viteConfig.lastIndexOf("\nimport ");
      if (lastImportIdx >= 0) {
        const endOfLine = viteConfig.indexOf("\n", lastImportIdx + 1);
        viteConfig = viteConfig.slice(0, endOfLine + 1) + importLine + "\n" + viteConfig.slice(endOfLine + 1);
      } else {
        viteConfig = importLine + "\n" + viteConfig;
      }
    }

    // Append zappWorkers() with config to the plugins array
    if (!viteConfig.includes("zappWorkers(")) {
      viteConfig = viteConfig.replace(
        /plugins:\s*\[/,
        "plugins: [zappWorkers({ headless: zappConfig.headless }), "
      );
    }

    await Bun.write(configPath, viteConfig);
  } else {
    // No vite.config found — create a minimal one
    await Bun.write(viteConfigPath, `import { defineConfig } from "vite";
import { zappWorkers } from "@zappdev/vite";
import zappConfig from "./zapp.config";

export default defineConfig({
  plugins: [zappWorkers({ headless: zappConfig.headless })],
});
`);
  }

  // 6. Add .zapp/ to .gitignore
  const gitignorePath = path.join(projectDir, ".gitignore");
  let gitignore = "";
  try { gitignore = await Bun.file(gitignorePath).text(); } catch {}
  if (!gitignore.includes(".zapp")) {
    gitignore += "\n# Zapp build artifacts\n.zapp/\nbin/\nsrc/zapp/\n";
    await Bun.write(gitignorePath, gitignore);
  }

  process.stdout.write(`\n[zapp] project created!\n\n`);
  process.stdout.write(`  cd ${name}\n`);
  process.stdout.write(`  bun install\n\n`);
  process.stdout.write(`  Then add to your entry file (e.g. src/main.ts):\n\n`);
  process.stdout.write(`    import { Window, WindowEvent, Services } from "@zappdev/runtime";\n\n`);
  process.stdout.write(`  Run:\n`);
  process.stdout.write(`    bun run dev      # development with Vite HMR\n`);
  process.stdout.write(`    bun run build    # production build\n`);
  process.stdout.write(`    bun run package  # .app bundle (macOS)\n\n`);
}
