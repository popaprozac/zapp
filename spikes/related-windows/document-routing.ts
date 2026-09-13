import { join, resolve } from "node:path";
import { mkdir } from "node:fs/promises";
import { runBoundedCommand } from "../../cli/src/bounded-process";
import { bundleWebviewBootstrapRaw } from "../../bootstrap/codegen";

if (process.platform !== "darwin") throw new Error("The native document-routing probe requires macOS.");
const root = resolve(import.meta.dir, "../..");
const zRoot = resolve(root, "../z-lang");
const related = process.argv.includes("--related");
const name = related ? "related-readiness" : "document-routing";
const artifacts = join(import.meta.dir, ".artifacts");
await mkdir(artifacts, { recursive: true });
const bootstrap = join(artifacts, `${name}-bootstrap.js`);
await Bun.write(bootstrap, await bundleWebviewBootstrapRaw());
const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch(request) {
  const path = new URL(request.url).pathname;
  if (related && (path === "/owner.html" || path === "/child.html")) {
    const owner = path === "/owner.html";
    const script = owner
      ? `globalThis.shared={value:41};const denied=window.open('/child.html');if(denied!==null)throw Error('unprepared child accepted');b.invoke('prepare',{}, {timeout:0}).then(()=>{if(!window.open('/child.html'))b.post(JSON.stringify({t:3,m:'fail'}))});`
      : `b.invoke('echo',{}, {timeout:0}).then(value=>{const pass=value===42&&!!document.head&&!!document.body&&opener.shared.value===41&&opener.document!==document; b.post(JSON.stringify({t:3,m:pass?'pass':'fail'}));window.close();});`;
    // The child's invocation is intentionally in its head, before body parsing.
    return new Response(`<!doctype html><head><title>Related readiness</title><script>const b=globalThis[Symbol.for('zapp.bridge')];${script}</script></head><body><h1>${owner ? "Owner" : "Child"}</h1></body>`,
      { headers: { "Content-Type": "text/html", "Cache-Control": "no-store" } });
  }
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
    const driver = frontend === "native" ? [process.env.Z_NATIVE_COMPILER ?? join(zRoot, ".z-cache/bootstrap/z")] : [process.execPath, join(zRoot, "compiler/src/cli.ts")];
    const input = related ? "related-readiness-native-smoke.zs" : "bridge-document-native-smoke.zs";
    const emission = await runBoundedCommand([...driver, "emit", join(root, "native/z/tests", input)], { cwd: root, timeoutMs: 120_000 });
    if (emission.status !== 0 || emission.timedOut) throw new Error(JSON.stringify({ frontend, emission }));
    const source = join(artifacts, `${name}-${frontend}.m`);
    await Bun.write(source, emission.stdout);
    for (const optimization of ["-O0", "-O2"]) {
      const binary = join(artifacts, `${name}-${frontend}${optimization}`);
      const compile = await runBoundedCommand(["xcrun", "clang", "-fobjc-arc", "-fblocks", optimization, "-g", "-Wall", "-Wextra", "-Werror", "-fsanitize=undefined", "-fno-sanitize-recover=all", "-mmacosx-version-min=14.0", "-framework", "AppKit", "-framework", "WebKit", "-framework", "CoreFoundation", "-lcompression", source, "-o", binary], { cwd: root, timeoutMs: 30_000 });
      if (compile.status !== 0 || compile.timedOut) throw new Error(JSON.stringify({ frontend, compile }));
      const outcome = await runBoundedCommand([binary, `http://127.0.0.1:${server.port}`, bootstrap], { cwd: root, timeoutMs: 15_000 });
      const pass = outcome.status === 0 && !outcome.timedOut && outcome.stderr === ""
        && outcome.stdout === (related
          ? "related readiness WebKit: pass=true created=1 rejected=1 replies=1 closed=1\n"
          : "document routing WebKit: pass=true commits=2 staleIgnored=true\n");
      results.push({ frontend, optimization, pass, ...outcome });
      console.log(`${pass ? "PASS" : "FAIL"} ${name} ${frontend} ${optimization}`);
      if (!pass) console.log(outcome);
    }
  }
} finally { server.stop(true); }
await Bun.write(join(artifacts, `${name}-results.json`), JSON.stringify(results, null, 2) + "\n");
if (results.some(result => !result.pass)) process.exitCode = 1;
