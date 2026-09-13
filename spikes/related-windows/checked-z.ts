import { join, resolve } from "node:path";
import { mkdir } from "node:fs/promises";
import { bundleWebviewBootstrapRaw } from "../../bootstrap/codegen";

if (process.platform !== "darwin") throw new Error("This probe requires macOS and a visible desktop.");
const root = import.meta.dir;
const project = join(root, "checked-z");
const artifacts = join(root, ".artifacts");
const zRoot = resolve(root, "../../../z-lang");
const compiler = process.env.Z_NATIVE_COMPILER ?? join(zRoot, ".z-cache/bootstrap/z");
const lifetime = process.argv.includes("--lifetime");
const stem = lifetime ? "checked-z-lifetime" : "checked-z";
await mkdir(artifacts, { recursive: true });
let ownerScript = "";
const bootstrapPath = join(artifacts, "checked-lifetime-bootstrap.js");
if (lifetime) {
  const bundle = await Bun.build({ entrypoints: [join(root, "checked-lifetime-owner.ts")], target: "browser", format: "iife" });
  if (!bundle.success) throw new Error(bundle.logs.map(log => log.message).join("\n"));
  ownerScript = await bundle.outputs[0].text();
  await Bun.write(bootstrapPath, await bundleWebviewBootstrapRaw());
}

async function run(command: string[], timeoutMs: number) {
  const child = Bun.spawn(command, { cwd: root, detached: true, stdout: "pipe", stderr: "pipe" });
  let timedOut = false;
  const kill = () => { try { process.kill(-child.pid, "SIGKILL"); } catch { try { child.kill("SIGKILL"); } catch {} } };
  const interrupt = () => { kill(); process.exit(130); };
  process.once("SIGINT", interrupt); process.once("SIGTERM", interrupt);
  const timer = setTimeout(() => { timedOut = true; kill(); }, timeoutMs);
  try {
    const [status, stdout, stderr] = await Promise.all([
      child.exited, new Response(child.stdout).text(), new Response(child.stderr).text(),
    ]);
    return { status, stdout, stderr, timedOut };
  } finally {
    clearTimeout(timer); process.off("SIGINT", interrupt); process.off("SIGTERM", interrupt);
  }
}

const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch(request) {
  const path = new URL(request.url).pathname;
  if (lifetime && path === "/owner.js") return new Response(ownerScript, { headers: { "Content-Type": "text/javascript" } });
  if (path === "/owner.html") return new Response(
    lifetime ? '<!doctype html><title>Checked Z lifetime owner</title><h1>Production bridge lifetime</h1><script src="/owner.js"></script>'
      : "<!doctype html><title>Checked Z owner</title><h1>Z owns the native delegate</h1><script>window.shared={value:42};window.open('/child.html');window.denied=window.open('/child.html');</script>",
    { headers: { "Content-Type": "text/html" } },
  );
  if (path === "/child.html") return new Response(
    lifetime ? "<!doctype html><title>Checked Z child</title><h1>Direct child bridge</h1><script>document.addEventListener('DOMContentLoaded',()=>window.webkit.messageHandlers.zapp.postMessage(JSON.stringify({t:4,m:'checked-document-ready'})));</script>"
      : "<!doctype html><title>Checked Z child</title><h1>Direct child bridge</h1><script>globalThis.__checkedRequest();</script>",
    { headers: { "Content-Type": "text/html" } },
  );
  return new Response("Not found", { status: 404 });
} });

const results = [];
try {
  for (const frontend of ["native", "stage0"]) {
    const command = frontend === "native" ? [compiler] : [process.execPath, join(zRoot, "compiler/src/cli.ts")];
    // Capture each frontend's emission separately: a cached executable build
    // need not rewrite a shared generated-source path after another frontend.
    const emission = await run([...command, "emit", lifetime ? join(project, "lifetime.zs") : project], 120_000);
    if (emission.status !== 0 || emission.timedOut) throw new Error(JSON.stringify({ frontend, emission }));
    const source = join(artifacts, `${stem}-${frontend}.m`);
    await Bun.write(source, emission.stdout);
    for (const optimization of ["-O0", "-O2"]) {
      const binary = join(artifacts, `${stem}-${frontend}${optimization}`);
      const compile = await run(["xcrun", "clang", "-fobjc-arc", "-fblocks", optimization, "-g",
        "-Wall", "-Wextra", "-Werror", "-fsanitize=undefined", "-fno-sanitize-recover=all",
        "-mmacosx-version-min=14.0", "-framework", "AppKit", "-framework", "WebKit",
        source, "-o", binary], 30_000);
      if (compile.status !== 0 || compile.timedOut) throw new Error(JSON.stringify({ frontend, compile }));
      const outcome = await run([binary, `http://127.0.0.1:${server.port}/owner.html`,
        ...(lifetime ? [`http://127.0.0.1:${server.port}/child.html`, bootstrapPath] : [])], 20_000);
      const pass = outcome.status === 0 && !outcome.timedOut && outcome.stderr === ""
        && outcome.stdout === (lifetime
          ? "checked-z lifetime: pass=true created=1 refused=1 ready=1 replies=1 pending=1 closed=1\n"
          : "checked-z related child: pass=true created=1 rejected=1 replies=1 closed=1\n");
      results.push({ frontend, optimization, pass, ...outcome });
      console.log(`${pass ? "PASS" : "FAIL"} ${stem} ${frontend} ${optimization}`);
      if (!pass) console.log(outcome);
      await Bun.write(join(artifacts, `${stem}-results.json`), JSON.stringify(results, null, 2));
    }
  }
} finally { server.stop(true); }
if (results.some(result => !result.pass)) process.exitCode = 1;
