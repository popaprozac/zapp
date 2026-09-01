// Scaffold a new Zapp project.
//
// Modes:
//   - `zapp init <name>`            interactive (asks framework + install)
//   - `zapp init <name> -t <tmpl>`  non-interactive (no prompts)
//   - `zapp init <name> --yes`      non-interactive, accept all defaults
//
// Pipeline:
//   1. (interactive) prompt name / framework / install-deps
//   2. `bun create-vite` with the chosen template
//   3. Drop in zapp/{app,build}.zc + zapp/app.nim (opt-in Nim entry),
//      zapp.config.ts, build/macos/.gitkeep
//   4. Inject `zapp()` into the template's vite.config.{ts,js}
//   5. (optional) `bun install` in the project dir

import path from "node:path";
import { mkdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import * as readline from "node:readline/promises";
import { stdin as input, stdout as output } from "node:process";
import { clog, clogError } from "./log";
import { renderNimCfg } from "./build-config";
import { resolveNativeDir } from "./paths";

/** Ensure the index.html viewport meta opts into the safe-area inset model on
 *  iOS (env(safe-area-inset-*) is 0 without viewport-fit=cover). Idempotent;
 *  no-op when there is no viewport meta. */
export function ensureViewportFitCover(html: string): string {
  return html.replace(
    /(<meta\s+name=["']viewport["']\s+content=["'])([^"']*)(["'])/i,
    (full, pre: string, content: string, post: string) =>
      /viewport-fit\s*=\s*cover/i.test(content)
        ? full
        : `${pre}${content.replace(/\s*$/, "")}, viewport-fit=cover${post}`,
  );
}

/** Add editor resolution for the compiler-owned `zapp:services` module. */
export function ensureZappServicePathMapping(source: string): string {
  if (source.includes('"zapp:services"')) return source;
  const compilerOptions = source.indexOf('"compilerOptions"');
  if (compilerOptions < 0) return source;
  const objectStart = source.indexOf("{", compilerOptions);
  if (objectStart < 0) return source;

  const paths = source.indexOf('"paths"', objectStart);
  if (paths >= 0) {
    const pathsStart = source.indexOf("{", paths);
    if (pathsStart >= 0) {
      return source.slice(0, pathsStart + 1)
        + '\n      "zapp:services": ["./.zapp/generated/services.ts"],'
        + source.slice(pathsStart + 1);
    }
  }

  return source.slice(0, objectStart + 1)
    + '\n    "paths": {\n      "zapp:services": ["./.zapp/generated/services.ts"]\n    },'
    + source.slice(objectStart + 1);
}

// Vite templates we surface as first-class. Each entry maps the display
// name to the `create-vite` template flag. Restricted to the "main four"
// (plus vanilla) so the prompt stays scannable — power users pass any
// create-vite template via `-t/--template <name>` directly.
const FRAMEWORKS: Array<{ id: string; label: string; template: string }> = [
  { id: "react",   label: "React (TypeScript)",   template: "react-ts" },
  { id: "svelte",  label: "Svelte (TypeScript)",  template: "svelte-ts" },
  { id: "vue",     label: "Vue (TypeScript)",     template: "vue-ts" },
  { id: "solid",   label: "Solid (TypeScript)",   template: "solid-ts" },
  { id: "vanilla", label: "Vanilla (TypeScript)", template: "vanilla-ts" },
];

// Map a CLI --template value to the resolved create-vite template name.
// Accepts our friendly id (`react`) or the raw template (`react-ts`).
// Returns null for unknown strings — caller decides whether to error
// or pass through to create-vite as a power-user override.
function resolveTemplate(input: string | null): string | null {
  if (!input) return null;
  const byId = FRAMEWORKS.find(f => f.id === input);
  if (byId) return byId.template;
  const byTemplate = FRAMEWORKS.find(f => f.template === input);
  if (byTemplate) return byTemplate.template;
  return null;
}

// Interactive prompt — readline-based, no new dep. Returns the chosen
// template (create-vite name) + install-deps decision.
async function promptFramework(): Promise<string> {
  // Closed/non-TTY stdin (CI, piped scripts): readline never resolves on a
  // closed stream — fall back to the default framework instead of hanging.
  if (!input.isTTY) {
    output.write(`  (non-interactive stdin — defaulting to ${FRAMEWORKS[0].label})\n`);
    return FRAMEWORKS[0].template;
  }
  const rl = readline.createInterface({ input, output });
  try {
    output.write("\n  Pick a frontend framework:\n");
    FRAMEWORKS.forEach((f, i) => {
      output.write(`    ${i + 1}) ${f.label}\n`);
    });
    output.write("\n");
    while (true) {
      const answer = (await rl.question(`  framework [1-${FRAMEWORKS.length}] (default 1): `)).trim();
      if (answer === "") return FRAMEWORKS[0].template;
      // Accept either the numeric index or the framework id.
      const n = Number.parseInt(answer, 10);
      if (Number.isFinite(n) && n >= 1 && n <= FRAMEWORKS.length) {
        return FRAMEWORKS[n - 1].template;
      }
      const byId = FRAMEWORKS.find(f => f.id === answer.toLowerCase());
      if (byId) return byId.template;
      output.write(`  not a valid choice — pick a number 1-${FRAMEWORKS.length} or a name (react, svelte, ...)\n`);
    }
  } finally {
    rl.close();
  }
}

async function promptYesNo(question: string, defaultYes: boolean): Promise<boolean> {
  // Closed/non-TTY stdin (CI, piped scripts): readline never resolves on a
  // closed stream — return the default instead of hanging forever.
  if (!input.isTTY) return defaultYes;
  const rl = readline.createInterface({ input, output });
  try {
    const suffix = defaultYes ? "(Y/n)" : "(y/N)";
    const answer = (await rl.question(`  ${question} ${suffix}: `)).trim().toLowerCase();
    if (answer === "") return defaultYes;
    return answer === "y" || answer === "yes";
  } finally {
    rl.close();
  }
}

interface InitOptions {
  name: string;
  template: string | null;   // null → prompt; non-null → skip prompt
  root: string;
  yes?: boolean;             // --yes shortcut: accept all defaults, skip prompts
  install?: boolean | null;  // null → prompt; bool → skip prompt
}

export async function runInit(opts: InitOptions) {
  const { name, root, yes } = opts;
  const projectDir = path.join(root, name);

  if (existsSync(projectDir)) {
    clogError(`directory '${name}' already exists`);
    process.exit(1);
  }

  // Resolve template: explicit flag wins. Otherwise prompt unless --yes.
  let template = resolveTemplate(opts.template);
  if (!template && opts.template) {
    // The flag was passed with an unrecognized value — pass through to
    // create-vite as a power-user override (Vite supports more templates
    // than we surface in the prompt).
    template = opts.template;
    clog(1, `using unrecognized template '${opts.template}' as create-vite passthrough`);
  }
  if (!template) {
    if (yes) {
      template = FRAMEWORKS[0].template;
    } else {
      template = await promptFramework();
    }
  }

  // Resolve install decision: explicit flag wins. Otherwise prompt —
  // unless --yes OR a template flag was passed: `-t` is documented as
  // "non-interactive (no prompts)", so it must skip this prompt too
  // (defaulting to install, same as --yes). Without this, `init -t x`
  // with a closed stdin (CI, scripts) hung forever on the prompt.
  let install: boolean;
  if (opts.install !== undefined && opts.install !== null) {
    install = opts.install;
  } else if (yes || opts.template) {
    install = true;
  } else {
    install = await promptYesNo("install dependencies now?", true);
  }

  // 1. Scaffold Vite project files (no install, no dev server).
  // create-vite has an --immediate flag that auto-installs + starts the dev
  // server, and an interactive prompt that does the same if confirmed.
  // --no-interactive skips the prompt and defaults to no install.
  clog(0, `creating ${name} with template ${template}...`);
  const viteProc = Bun.spawn(
    ["bunx", "create-vite@latest", name, "--template", template, "--no-interactive"],
    { cwd: root, stdout: "inherit", stderr: "inherit" },
  );
  if ((await viteProc.exited) !== 0) {
    clogError("vite scaffold failed");
    process.exit(1);
  }

  // 1b. Patch the scaffolded index.html to add viewport-fit=cover so that
  //     env(safe-area-inset-*) resolves correctly on iOS (#577).
  {
    const idx = path.join(projectDir, "index.html");
    const f = Bun.file(idx);
    if (await f.exists()) {
      const html = await f.text();
      const next = ensureViewportFitCover(html);
      if (next !== html) await Bun.write(idx, next);
    }
  }

  // 2. Add zapp/ native code
  const zappDir = path.join(projectDir, "zapp");
  await mkdir(zappDir, { recursive: true });

  // 2b. Add zapp/app.nim — the app's native entry (Nim, the default build).
  // One file, no build.nim (the entry is `quit(runApp())` at top level). Power
  // users link/include native libs here with Nim pragmas ({.passL.},
  // {.compile.}); everyone else drives frameworks/links declaratively via
  // `native:` in zapp.config.ts. (Legacy Zen-C builds are opt-out via
  // ZAPP_NATIVE_LANG=zc and are not scaffolded.)
  await Bun.write(path.join(zappDir, "app.nim"), `## Your app's native entry, authored in Nim — the default native build.
## \`import zapp\` re-exports the app surface (newApp, registerService,
## WindowOptions, createWindow, …). Service handlers are \`proc(args: JsonNode):
## string\`, reachable from the webview via \`Services.invoke("name", …)\`.
import zapp

proc greet(app: App, args: JsonNode): string =
  "Hello from Zapp!"

proc onReady(id: cint, handle: pointer) {.cdecl.} =
  ## Reveal the window once its webview bridge is up (no empty-window flash).
  ## Must be a top-level cdecl proc — it's registered as a C function pointer.
  Window(id: id, handle: handle).show()

proc runApp(): int =
  let a = newApp("${name}", terminateAfterLastWindowClosed = true)
  a.service.add("greet", greet)

  let win = a.window.create(WindowOptions(
    title: "${name}",
    visible: false,                   # deferred show — revealed by onReady
    inspectable: Inspectable.Auto,   # web inspector: on in dev, off in prod
  ))
  win.onReady(onReady)

  a.run()

quit(runApp())
`);

  // Editor config for the scaffolded Nim entry — so `import zapp` resolves in the
  // editor immediately, before the first build. Same generator the build uses.
  // Gitignored below; the build regenerates it.
  const frameworkNimDir = path.join(resolveNativeDir(), "nim");
  await Bun.write(
    path.join(zappDir, "nim.cfg"),
    renderNimCfg({ frameworkNimDir, zappDir: path.join(projectDir, ".zapp") }),
  );

  // 3. Add zapp.config.ts. defineConfig supplies contextual typing today and
  // can accept a target/mode-aware factory when the application needs one.
  // The CLI resolves it once into .zapp/config.resolved.json before Vite runs.
  const identifier = `com.zapp.${name.toLowerCase().replace(/[^a-z0-9]/g, "")}`;
  await Bun.write(path.join(projectDir, "zapp.config.ts"), `import { defineConfig } from "@zappdev/cli/config";

export default defineConfig({
  application: {
    name: "${name}",
    identifier: "${identifier}",
    version: "0.1.0",
  },
  // Add application TypeScript workers that start after services and stop
  // before services during application teardown.
  // New projects default to \`engine: "zjs"\` — first-party,
  // cross-platform, small, iOS-friendly. On macOS you can opt into
  // \`engine: "bare-jsc"\` for JIT (zero bundle cost via system JSC)
  // at the price of opting into bare-* packages for web APIs.
  //
  //   workers: {
  //     application: {
  //       db: { script: "src/workers/db.ts", engine: "zjs" },
  //     },
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

  // 5. Inject the unified zapp() plugin into the template's vite.config.ts
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
      `import { zapp } from "@zappdev/vite";`,
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

    // The plugin reads the normalized config snapshot the CLI writes before
    // Vite starts, so contextual config factories stay out of Vite's graph.
    if (!viteConfig.includes("zapp(")) {
      viteConfig = viteConfig.replace(
        /plugins:\s*\[/,
        "plugins: [zapp(), "
      );
    }

    await Bun.write(configPath, viteConfig);
  } else {
    // No vite.config found — create a minimal one
    await Bun.write(viteConfigPath, `import { defineConfig } from "vite";
import { zapp } from "@zappdev/vite";

export default defineConfig({
  plugins: [zapp()],
});
`);
  }

  // TypeScript does not consult Vite aliases. Point generated projects at
  // the same compiler-owned module so autocomplete and go-to-definition work.
  const tsconfigCandidates = [
    path.join(projectDir, "tsconfig.app.json"),
    path.join(projectDir, "tsconfig.json"),
  ];
  const tsconfigPath = tsconfigCandidates.find((candidate) => existsSync(candidate));
  if (tsconfigPath) {
    const tsconfig = await Bun.file(tsconfigPath).text();
    await Bun.write(tsconfigPath, ensureZappServicePathMapping(tsconfig));
  }

  // 6. Scaffold build/ directory for platform build inputs (icons,
  //    Info.plist extras, future Windows resources).
  await mkdir(path.join(projectDir, "build", "macos"), { recursive: true });
  await Bun.write(path.join(projectDir, "build", "macos", ".gitkeep"), "");
  await Bun.write(path.join(projectDir, "build", "README.md"), `# build/

Place platform-specific build inputs here. The CLI picks them up
automatically at \`bun run package\` time.

## macOS

Drop any of these into \`build/macos/\`:

- \`icon.icon\` — Icon Composer bundle (best for macOS 26+ liquid glass)
- \`icon.icns\` — traditional icon
- \`icon.iconset\` — source set (CLI converts via \`iconutil\`)
- \`icon.png\` — single 1024×1024 (CLI compiles via \`actool\`)
- \`Info.plist.extra\` — partial plist; keys here merge into the
  generated \`Info.plist\` at package time.
- \`app.entitlements\` — code-signing entitlements. Passed to
  \`codesign --entitlements\` during both \`zapp dev\` and
  \`zapp package\`. Map entries in \`zapp.config.ts →
  targets.macOS.entitlements\` override matching keys from this file.

### Icon priority

1. \`targets.macOS.icon\` path set in \`zapp.config.ts\` (explicit override)
2. \`build/macos/icon.{icon,icns,iconset,png}\` (this directory)

If neither is present, Zapp packages the application without imposing a
framework-owned icon. Add application branding before distribution.

### Info.plist.extra example

\`\`\`xml
<key>LSUIElement</key>
<true/>
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
</dict>
\`\`\`

Keep only the keys you want to add or override. Don't wrap in
\`<plist>\` or \`<dict>\` — just the key/value pairs.

### Entitlements example

\`build/macos/app.entitlements\`:

\`\`\`xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
</dict>
</plist>
\`\`\`

Privileged entitlements (\`com.apple.developer.*\`,
\`com.apple.security.app-sandbox\`) require a real
\`macos.signingIdentity\`. Ad-hoc signing silently ignores them.

## Windows

Placeholder for future Windows build inputs (\`icon.ico\`, app
manifest, resource file). Windows packaging is in progress.
`);

  // 7. Add .zapp/ to .gitignore
  const gitignorePath = path.join(projectDir, ".gitignore");
  let gitignore = "";
  try { gitignore = await Bun.file(gitignorePath).text(); } catch {}
  if (!gitignore.includes(".zapp")) {
    gitignore += "\n# Zapp build artifacts\n.zapp/\nbin/\nsrc/zapp/\nzapp/nim.cfg\n";
    await Bun.write(gitignorePath, gitignore);
  }

  // 8. Auto-install dependencies if the user opted in.
  if (install) {
    clog(0, "installing dependencies (bun install)...");
    const installProc = Bun.spawn(["bun", "install"], {
      cwd: projectDir, stdout: "inherit", stderr: "inherit",
    });
    if ((await installProc.exited) !== 0) {
      clogError("bun install failed — you can re-run it manually inside the project dir");
    }
  }

  // 9. Closing message — branch on install state so the next-step
  // section reads cleanly in both cases.
  const frameworkLabel = FRAMEWORKS.find(f => f.template === template)?.label ?? template;
  process.stdout.write(`\n[zapp] project '${name}' created (${frameworkLabel}).\n\n`);
  if (!install) {
    process.stdout.write(`  cd ${name}\n`);
    process.stdout.write(`  bun install\n\n`);
  } else {
    process.stdout.write(`  cd ${name}\n\n`);
  }
  process.stdout.write(`  Then add to your entry file (e.g. src/main.ts):\n\n`);
  process.stdout.write(`    import { Services } from "@zappdev/runtime";\n`);
  process.stdout.write(`    const greeting = await Services.invoke<unknown, string>("greet");\n\n`);
  process.stdout.write(`  Run:\n`);
  process.stdout.write(`    bun run dev      # development with Vite HMR\n`);
  process.stdout.write(`    bun run build    # production build\n`);
  process.stdout.write(`    bun run package  # .app bundle (macOS)\n\n`);
}
