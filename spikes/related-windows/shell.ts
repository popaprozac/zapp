// Real WebKit readiness against Vite and the production embedded-asset handler.
// --factory exercises the exported API; other modes retain private phase probes.
import { join, resolve } from "node:path";
import { cp, mkdir, rm } from "node:fs/promises";
import { RELATED_DOCUMENT_SHELL_PATH } from "../../bootstrap/related-document";
import { bundleWebviewBootstrapRaw } from "../../bootstrap/codegen";
import { generateAssetManifestZ } from "../../cli/src/assets";
import { runBoundedCommand, terminateProcessTree } from "../../cli/src/bounded-process";

if (process.platform !== "darwin") throw new Error("The related-shell probe requires macOS.");
const root = resolve(import.meta.dir, "../..");
const zRoot = resolve(root, "../z-lang");
const retirement = process.argv.includes("--retirement");
const lifetime = process.argv.includes("--lifetime");
const churn = process.argv.includes("--churn");
const factory = process.argv.includes("--factory") || churn || lifetime;
const authority = process.argv.includes("--authority") || factory;
const production = process.argv.includes("--production") || retirement || authority;
const artifacts = join(import.meta.dir, ".artifacts", lifetime ? "lifetime" : churn ? "churn" : factory ? "factory" : authority ? "authority" : retirement ? "retirement" : production ? "production" : "shell");
// All rewritten/generated compiler inputs stay in the ignored probe workspace.
await rm(artifacts, { recursive: true, force: true });
const workspace = join(artifacts, "native", "z");
await mkdir(join(workspace, "tests"), { recursive: true });
await cp(join(root, "native/z/framework"), join(workspace, "framework"), { recursive: true });
await cp(join(root, "native/z/api"), join(workspace, "api"), { recursive: true });
await cp(join(root, "native/z/z.json"), join(workspace, "z.json"));
await cp(join(root, "native/z/tests", authority ? "related-authority-native-smoke.zs" : production ? "related-production-native-smoke.zs" : "related-readiness-native-smoke.zs"), join(workspace, "tests/probe.zs"));
if (churn || lifetime) {
  // Isolate framework ownership from AppKit's ordering-animation lifetime.
  // Only the deterministic churn scenario disables animations; animated churn
  // and all other creation/close cases keep the production presentation path.
  const windowSource = join(workspace, "framework/platform/macos/window-resize.zs");
  const source = await Bun.file(windowSource).text();
  const anchor = "this.releasedWhenClosed = false;";
  if (!source.includes(anchor)) throw new Error("window churn overlay lost its constructor anchor");
  await Bun.write(windowSource, 'import probeProcess from "std/process";\n' + source.replace(anchor,
    anchor + '\n    const probeArguments = probeProcess.args();\n    if (probeArguments.length > 3 && probeArguments[3] == "--factory-churn") this.animationBehavior = WebKit.NSWindowAnimationBehaviorNone;'));
}
const assets = join(artifacts, "frontend");
await mkdir(assets, { recursive: true });
if (production) {
  const owner = await Bun.build({ entrypoints: [join(import.meta.dir, factory ? "factory-owner.ts" : authority ? "authority-owner.ts" : "production-owner.ts")],
    target: "browser", format: "iife", minify: true });
  if (!owner.success) throw new Error(owner.logs.map(log => log.message).join("\n"));
  await Bun.write(join(assets, "owner.js"), await owner.outputs[0].text());
}
if (authority) await Bun.write(join(assets, "frame.html"), "<!doctype html><title>Unprivileged subframe</title><body></body>");
await Bun.write(join(assets, "owner.html"), production
  ? '<!doctype html><head><title>Production related owner</title></head><body><script src="/owner.js"></script></body>'
  : `<!doctype html><head><title>Related shell owner</title></head><body><h1>Related shell owner</h1><script>
globalThis.shared={value:41};
const b=globalThis[Symbol.for('zapp.bridge')];
if(window.open(${JSON.stringify(RELATED_DOCUMENT_SHELL_PATH)})!==null)throw Error('unprepared child accepted');
b.invoke('prepareFailure',{}, {timeout:0}).then(()=>{if(window.open(${JSON.stringify(RELATED_DOCUMENT_SHELL_PATH)})!==null)throw Error('failed child accepted');return b.invoke('prepare',{}, {timeout:0})}).then(()=>{if(!window.open(${JSON.stringify(RELATED_DOCUMENT_SHELL_PATH)}))b.post(JSON.stringify({t:3,m:'fail'}))}).catch(()=>b.post(JSON.stringify({t:3,m:'fail'})));
</script></body>`);
await generateAssetManifestZ(artifacts, "frontend", { embed: true, compress: true,
  outputPath: join(workspace, "framework/platform/macos/configured-assets.zs") });
const bootstrap = join(artifacts, "bootstrap.js");
await Bun.write(bootstrap, await bundleWebviewBootstrapRaw());
if (production) {
  // Probe-only configuration overlay. The production allocator still consumes
  // the normal configured bootstrap/origin; no test hook enters framework code.
  const configured = join(workspace, "framework/platform/macos/configured-webview.zs");
  const source = await Bun.file(configured).text();
  await Bun.write(configured, 'import process from "std/process";\nimport fs from "std/fs";\n' + source
    .replace('return "zapp://app/";', 'const args = process.args(); return `${args[0]}/`;')
    .replace('return "";', 'const args = process.args(); return match (attempt fs.readText(args[1])) { success(value) => value; failure(_) => ""; };'));
}

const readiness = join(artifacts, "server.json");
const server = Bun.spawn([process.execPath, join(import.meta.dir, "shell-server.ts"), assets, readiness], {
  cwd: root, detached: true, stdout: "inherit", stderr: "inherit",
});
const results = [];
try {
  const deadline = Date.now() + 10_000;
  while (!(await Bun.file(readiness).exists())) {
    if (server.exitCode !== null || Date.now() >= deadline) throw new Error("Vite probe server did not become ready");
    await Bun.sleep(50);
  }
  const address = await Bun.file(readiness).json() as { port: number };
  if (!Number.isInteger(address.port) || address.port <= 0) throw new Error("invalid Vite probe port");
  for (const frontend of process.argv.includes("--stage0-only") ? ["stage0"] : ["native", "stage0"]) {
    const driver = frontend === "native"
      ? [process.env.Z_NATIVE_COMPILER ?? join(zRoot, ".z-cache/bootstrap/z")]
      : [process.execPath, join(zRoot, "compiler/src/cli.ts")];
    const emission = await runBoundedCommand([...driver, "emit", join(workspace, "tests/probe.zs")], { cwd: root, timeoutMs: 120_000 });
    if (emission.status !== 0 || emission.timedOut) throw new Error(JSON.stringify({ frontend, emission }));
    const source = join(artifacts, `${frontend}.m`);
    await Bun.write(source, emission.stdout);
    for (const optimization of ["-O0", "-O2"]) {
      const binary = join(artifacts, `${frontend}${optimization}`);
      const compile = await runBoundedCommand(["xcrun", "clang", "-fobjc-arc", "-fblocks", optimization,
        "-g", "-Wall", "-Wextra", "-Werror", "-fsanitize=undefined", "-fno-sanitize-recover=all",
        "-I", join(workspace, "framework/worker"),
        "-mmacosx-version-min=14.0", "-framework", "AppKit", "-framework", "WebKit",
        "-framework", "CoreFoundation", "-framework", "QuartzCore", "-lcompression", source, "-o", binary], { cwd: root, timeoutMs: 30_000 });
      if (compile.status !== 0 || compile.timedOut) throw new Error(JSON.stringify({ frontend, compile }));
      for (const mode of ["vite", "packaged"]) {
        for (const scenario of churn ? ["factory-churn"] : factory ? ["factory-ready", "factory-rollback", "factory-invalid", "factory-veto", "factory-denied", ...(lifetime ? ["factory-churn", "factory-animated-churn"] : [])] : authority
          ? ["subframe", "denied", "nested-child-close", "nested-owner-close"]
          : retirement
          ? ["owner-replace", "owner-terminate", "child-replace", "child-terminate", "child-navigation"]
          : production ? ["adopted", "stopped", "family", "immediate"] : ["readiness"]) {
          const origin = mode === "vite" ? `http://127.0.0.1:${address.port}` : "zapp://app";
          const flags = scenario !== "adopted" && scenario !== "readiness" ? [`--${scenario}`] : [];
          const outcome = await runBoundedCommand([binary, origin, bootstrap, "--shell", ...flags], {
            cwd: root, timeoutMs: scenario === "factory-churn" ? 30_000 : 15_000,
          });
          const expectedStderr = authority && scenario === "subframe"
            ? "blocked native bridge message from a WebView subframe\n" : "";
          // AppKit can hold native objects for ordering animations, but may
          // never keep the Z runtime graph alive. Record those native counts.
          const observedLines = outcome.stdout.trimEnd().split("\n");
          const animatedChurnPassed = observedLines.length === 5
            && [4, 8, 12, 16].every((count, index) => new RegExp(`^related churn: observed=${count} alive=0 native=[0-9]+$`).test(observedLines[index]))
            && observedLines[4] === "related authority WebKit: pass=true completed=16 closed=16 vetoes=0";
          const pass = outcome.status === 0 && !outcome.timedOut && outcome.stderr === expectedStderr
            && (scenario === "factory-animated-churn" ? animatedChurnPassed : outcome.stdout === (scenario === "factory-churn"
              ? [4, 8, 12, 16].map(count => `related churn: observed=${count} alive=0 native=0`).join("\n") + "\nrelated authority WebKit: pass=true completed=16 closed=16 vetoes=0\n"
              : authority
              ? factory
                ? `related authority WebKit: pass=true completed=${scenario === "factory-ready" ? 2 : scenario === "factory-veto" ? 1 : 0} closed=${scenario === "factory-ready" ? 2 : scenario === "factory-denied" ? 0 : 1} vetoes=${scenario === "factory-veto" ? 1 : 0}\n`
                : `related authority WebKit: pass=true completed=${scenario === "denied" ? 0 : scenario === "subframe" ? 1 : 3} closed=${scenario === "denied" ? 0 : scenario === "subframe" ? 1 : 3} vetoes=${scenario.startsWith("nested-") ? 1 : 0}\n`
              : production
              ? scenario === "stopped"
                ? "related production WebKit: pass=true completed=0 failed=2 echoes=0 closed=0 vetoed=0\n"
                : `related production WebKit: pass=true completed=1 failed=1 echoes=${scenario === "immediate" ? 0 : 1} closed=1 vetoed=${scenario === "immediate" ? 0 : scenario === "family" ? 3 : 1}\n`
              : "related readiness WebKit: pass=true created=1 rejected=1 replies=1 closed=1 rolledBack=1 released=1\n"));
          results.push({ frontend, optimization, mode, scenario, pass, ...outcome });
          console.log(`${pass ? "PASS" : "FAIL"} related shell ${frontend} ${optimization} ${mode} ${scenario}`);
          if (!pass) console.log(outcome);
          if (!pass && authority) throw new Error("Related authority case failed; see the saved partial results.");
        }
      }
    }
  }
} finally {
  try {
    await Bun.write(join(artifacts, "results.json"), JSON.stringify(results, null, 2) + "\n");
  } finally {
    await terminateProcessTree(server);
  }
}
if (results.some(result => !result.pass)) process.exitCode = 1;
