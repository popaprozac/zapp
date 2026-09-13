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
const artifacts = join(import.meta.dir, ".artifacts", "shell");
// All rewritten/generated compiler inputs stay in the ignored probe workspace.
await rm(artifacts, { recursive: true, force: true });
const workspace = join(artifacts, "native", "z");
await mkdir(join(workspace, "tests"), { recursive: true });
await cp(join(root, "native/z/framework"), join(workspace, "framework"), { recursive: true });
await cp(join(root, "native/z/api"), join(workspace, "api"), { recursive: true });
await cp(join(root, "native/z/z.json"), join(workspace, "z.json"));
await cp(join(root, "native/z/tests/related-readiness-native-smoke.zs"), join(workspace, "tests/probe.zs"));
const assets = join(artifacts, "frontend");
await mkdir(assets, { recursive: true });
await Bun.write(join(assets, "owner.html"), `<!doctype html><head><title>Related shell owner</title></head><body><h1>Related shell owner</h1><script>
globalThis.shared={value:41};
const b=globalThis[Symbol.for('zapp.bridge')];
if(window.open(${JSON.stringify(RELATED_DOCUMENT_SHELL_PATH)})!==null)throw Error('unprepared child accepted');
b.invoke('prepare',{}, {timeout:0}).then(()=>{if(!window.open(${JSON.stringify(RELATED_DOCUMENT_SHELL_PATH)}))b.post(JSON.stringify({t:3,m:'fail'}))});
</script></body>`);
await generateAssetManifestZ(artifacts, "frontend", { embed: true, compress: true,
  outputPath: join(workspace, "framework/platform/macos/configured-assets.zs") });
const bootstrap = join(artifacts, "bootstrap.js");
await Bun.write(bootstrap, await bundleWebviewBootstrapRaw());

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
        "-framework", "CoreFoundation", "-lcompression", source, "-o", binary], { cwd: root, timeoutMs: 30_000 });
      if (compile.status !== 0 || compile.timedOut) throw new Error(JSON.stringify({ frontend, compile }));
      for (const mode of ["vite", "packaged"]) {
        const origin = mode === "vite" ? `http://127.0.0.1:${address.port}` : "zapp://app";
        const outcome = await runBoundedCommand([binary, origin, bootstrap, "--shell"], { cwd: root, timeoutMs: 15_000 });
        const pass = outcome.status === 0 && !outcome.timedOut && outcome.stderr === ""
          && outcome.stdout === "related readiness WebKit: pass=true created=1 rejected=1 replies=1 closed=1\n";
        results.push({ frontend, optimization, mode, pass, ...outcome });
        console.log(`${pass ? "PASS" : "FAIL"} related shell ${frontend} ${optimization} ${mode}`);
        if (!pass) console.log(outcome);
      }
    }
  }
} finally {
  await server.close();
  await Bun.write(join(artifacts, "results.json"), JSON.stringify(results, null, 2) + "\n");
}
if (results.some(result => !result.pass)) process.exitCode = 1;
