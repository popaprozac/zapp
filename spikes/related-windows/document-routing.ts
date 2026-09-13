import { join, resolve } from "node:path";
import { mkdir } from "node:fs/promises";
import { runBoundedCommand } from "../../cli/src/bounded-process";
import { bundleWebviewBootstrapRaw } from "../../bootstrap/codegen";

if (process.platform !== "darwin") throw new Error("The native document-routing probe requires macOS.");
const root = resolve(import.meta.dir, "../..");
const zRoot = resolve(root, "../z-lang");
const artifacts = join(import.meta.dir, ".artifacts");
await mkdir(artifacts, { recursive: true });
const bootstrap = join(artifacts, "document-routing-bootstrap.js");
await Bun.write(bootstrap, await bundleWebviewBootstrapRaw());
const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch(request) {
  const path = new URL(request.url).pathname;
  const old = path === "/old.html";
  if (!old && path !== "/new.html") return new Response("Not found", { status: 404 });
  const operation = old ? "b.invoke('hold',{}, {timeout:0}).catch(()=>{});"
    : "b.invoke('ping',{}, {timeout:0}).then(value=>b.post(JSON.stringify({t:3,m:value===42?'pass':'fail'})));";
  return new Response(`<!doctype html><title>Document replacement</title><h1>${old ? "Original" : "Replacement"} document</h1><script>const b=globalThis[Symbol.for('zapp.bridge')];${operation}</script>`,
    { headers: { "Content-Type": "text/html", "Cache-Control": "no-store" } });
} });
const results = [];
try {
  for (const frontend of ["native", "stage0"]) {
    const driver = frontend === "native" ? [join(zRoot, ".z-cache/bootstrap/z")] : [process.execPath, join(zRoot, "compiler/src/cli.ts")];
    const emission = await runBoundedCommand([...driver, "emit", join(root, "native/z/tests/bridge-document-native-smoke.zs")], { cwd: root, timeoutMs: 120_000 });
    if (emission.status !== 0 || emission.timedOut) throw new Error(JSON.stringify({ frontend, emission }));
    const source = join(artifacts, `document-routing-${frontend}.m`);
    await Bun.write(source, emission.stdout);
    for (const optimization of ["-O0", "-O2"]) {
      const binary = join(artifacts, `document-routing-${frontend}${optimization}`);
      const compile = await runBoundedCommand(["xcrun", "clang", "-fobjc-arc", "-fblocks", optimization, "-g", "-Wall", "-Wextra", "-Werror", "-fsanitize=undefined", "-fno-sanitize-recover=all", "-mmacosx-version-min=14.0", "-framework", "AppKit", "-framework", "WebKit", "-framework", "CoreFoundation", source, "-o", binary], { cwd: root, timeoutMs: 30_000 });
      if (compile.status !== 0 || compile.timedOut) throw new Error(JSON.stringify({ frontend, compile }));
      const outcome = await runBoundedCommand([binary, `http://127.0.0.1:${server.port}`, bootstrap], { cwd: root, timeoutMs: 15_000 });
      const pass = outcome.status === 0 && !outcome.timedOut && outcome.stderr === ""
        && outcome.stdout === "document routing WebKit: pass=true commits=2 staleIgnored=true\n";
      results.push({ frontend, optimization, pass, ...outcome });
      console.log(`${pass ? "PASS" : "FAIL"} document routing ${frontend} ${optimization}`);
      if (!pass) console.log(outcome);
    }
  }
} finally { server.stop(true); }
await Bun.write(join(artifacts, "document-routing-results.json"), JSON.stringify(results, null, 2) + "\n");
if (results.some(result => !result.pass)) process.exitCode = 1;
