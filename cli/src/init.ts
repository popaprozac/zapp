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

  // 1. Create Vite project
  process.stdout.write(`[zapp] creating ${name} with template ${template}...\n`);
  const viteProc = Bun.spawn(["bun", "create", "vite", name, "--template", template], {
    cwd: root,
    stdout: "inherit",
    stderr: "inherit",
  });
  if ((await viteProc.exited) !== 0) {
    process.stderr.write("[zapp] vite scaffold failed\n");
    process.exit(1);
  }

  // 2. Add zapp/ native code
  const zappDir = path.join(projectDir, "zapp");
  await mkdir(zappDir, { recursive: true });

  await Bun.write(path.join(zappDir, "app.zc"), `import "app/app.zc";

fn greet(_app: App*, args: string) -> string {
    return args;
}

fn on_ready(_id: int, _handle: void*) -> void {
    Window{id: _id, handle: _handle}.show();
}

fn run_app() -> int {
    let config = AppConfig{
        name: "${name}",
        applicationShouldTerminateAfterLastWindowClosed: true,
        webContentInspectable: -1,
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
//> macos: define: ZAPP_WORKER_ENGINE_JSC
// Uncomment below for txiki.js (adds fetch, WebSocket, timers — +6MB binary):
// //> define: ZAPP_WORKER_ENGINE_TXIKI
// import "workers-txiki.zc";

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

  // 3. Add zapp.config.ts
  const identifier = `com.zapp.${name.toLowerCase().replace(/[^a-z0-9]/g, "")}`;
  await Bun.write(path.join(projectDir, "zapp.config.ts"), `export default {
  name: "${name}",
  identifier: "${identifier}",
  version: "0.1.0",
};
`);

  // 4. Update package.json — add deps and scripts
  const pkgPath = path.join(projectDir, "package.json");
  const pkgObj = JSON.parse(await Bun.file(pkgPath).text());

  pkgObj.scripts = {
    ...pkgObj.scripts,
    "dev": "zapp dev",
    "build": "zapp build",
    "generate": "zapp generate",
  };

  pkgObj.dependencies = {
    ...(pkgObj.dependencies ?? {}),
    "@zappdev/runtime": "latest",
  };
  pkgObj.devDependencies = {
    ...(pkgObj.devDependencies ?? {}),
    "@zappdev/cli": "latest",
  };

  await Bun.write(pkgPath, JSON.stringify(pkgObj, null, 2));

  // 5. Add .zapp/ to .gitignore
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
  process.stdout.write(`    zapp dev      # development with Vite HMR\n`);
  process.stdout.write(`    zapp build    # production build\n\n`);
}
