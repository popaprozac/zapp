// Real WebKit readiness against Vite and the production embedded-asset handler.
// No public factory is exposed by this fixture.
import { join, resolve } from "node:path";
import { cp, mkdir, rm } from "node:fs/promises";
import { createServer } from "vite";
import { zapp } from "../../vite/src/index";
import { RELATED_DOCUMENT_SHELL_PATH } from "../../bootstrap/related-document";
import { bundleWebviewBootstrapRaw } from "../../bootstrap/codegen";
import { generateAssetManifestZ } from "../../cli/src/assets";
import { runBoundedCommand } from "../../cli/src/bounded-process";

if (process.platform !== "darwin") throw new Error("The related-shell probe requires macOS.");
const root = resolve(import.meta.dir, "../..");
const zRoot = resolve(root, "../z-lang");
const production = process.argv.includes("--production");
const artifacts = join(import.meta.dir, ".artifacts", production ? "production" : "shell");
// All rewritten/generated compiler inputs stay in the ignored probe workspace.
await rm(artifacts, { recursive: true, force: true });
const workspace = join(artifacts, "native", "z");
await mkdir(join(workspace, "tests"), { recursive: true });
await cp(join(root, "native/z/framework"), join(workspace, "framework"), { recursive: true });
await cp(join(root, "native/z/api"), join(workspace, "api"), { recursive: true });
await cp(join(root, "native/z/z.json"), join(workspace, "z.json"));
await cp(join(root, "native/z/tests", production ? "related-production-native-smoke.zs" : "related-readiness-native-smoke.zs"), join(workspace, "tests/probe.zs"));
const assets = join(artifacts, "frontend");
await mkdir(assets, { recursive: true });
await Bun.write(join(assets, "owner.html"), production ? `<!doctype html><head><title>Production related owner</title></head><body><script>
globalThis.shared={value:41};
const b=globalThis[Symbol.for('zapp.bridge')];
(async()=>{
  if(window.open(${JSON.stringify(RELATED_DOCUMENT_SHELL_PATH)})!==null)throw Error('unprepared popup');
  const failedURL=await b.invoke('prepareFailure',{}, {timeout:0});
  const failed=window.open(failedURL);if(!failed)throw Error('missing partial allocation');
  await b.invoke('rollback',{}, {timeout:0});
  const url=await b.invoke('prepare',{}, {timeout:0});
  const completion=b.invoke('completion',{}, {timeout:0});
  const stopped=location.search.includes('stopped=1');
  if(stopped)await b.invoke('stopManager',{}, {timeout:0});
  const child=window.open(url);if(!child)throw Error('missing child');
  const completed=await completion;
  if(stopped){if(completed!==false)throw Error('stopped manager published child');b.post(JSON.stringify({t:3,m:'pass'}));return;}
  if(completed!==true)throw Error('child adoption failed');
  if(!child.document.head||!child.document.body||child.document.scripts.length||child.document.body.children.length)throw Error('shell not empty/ready');
  if(child.opener.shared!==shared||child.document===document)throw Error('wrong document family');
  const result=await child[Symbol.for('zapp.bridge')].invoke('echo',{}, {timeout:0});
  if(result!==42)throw Error('wrong child bridge');
  child.close();
  b.post(JSON.stringify({t:3,m:'pass'}));
})().catch(error=>{console.error(error);b.post(JSON.stringify({t:3,m:'fail'}))});
</script></body>` : `<!doctype html><head><title>Related shell owner</title></head><body><h1>Related shell owner</h1><script>
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

const server = await createServer({ root: assets, configFile: false, plugins: [zapp()],
  server: { host: "127.0.0.1", port: 0 }, logLevel: "silent" });
const results = [];
try {
  await server.listen();
  const address = server.httpServer!.address();
  if (address === null || typeof address === "string") throw new Error("missing Vite port");
  for (const frontend of ["native", "stage0"]) {
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
        "-mmacosx-version-min=14.0", "-framework", "AppKit", "-framework", "WebKit",
        "-framework", "CoreFoundation", "-framework", "QuartzCore", "-lcompression", source, "-o", binary], { cwd: root, timeoutMs: 30_000 });
      if (compile.status !== 0 || compile.timedOut) throw new Error(JSON.stringify({ frontend, compile }));
      for (const mode of ["vite", "packaged"]) {
        for (const scenario of production ? ["adopted", "stopped"] : ["readiness"]) {
          const origin = mode === "vite" ? `http://127.0.0.1:${address.port}` : "zapp://app";
          const outcome = await runBoundedCommand([binary, origin, bootstrap, "--shell", ...(scenario === "stopped" ? ["--stopped"] : [])], { cwd: root, timeoutMs: 15_000 });
          const pass = outcome.status === 0 && !outcome.timedOut && outcome.stderr === ""
            && outcome.stdout === (production
              ? scenario === "stopped"
                ? "related production WebKit: pass=true completed=0 failed=2 echoes=0 closed=0 vetoed=0\n"
                : "related production WebKit: pass=true completed=1 failed=1 echoes=1 closed=1 vetoed=1\n"
              : "related readiness WebKit: pass=true created=1 rejected=1 replies=1 closed=1 rolledBack=1 released=1\n");
          results.push({ frontend, optimization, mode, scenario, pass, ...outcome });
          console.log(`${pass ? "PASS" : "FAIL"} related shell ${frontend} ${optimization} ${mode} ${scenario}`);
          if (!pass) console.log(outcome);
        }
      }
    }
  }
} finally {
  await server.close();
  await Bun.write(join(artifacts, "results.json"), JSON.stringify(results, null, 2) + "\n");
}
if (results.some(result => !result.pass)) process.exitCode = 1;
