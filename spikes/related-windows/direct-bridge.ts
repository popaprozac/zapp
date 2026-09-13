import { join } from "node:path";
import { mkdir } from "node:fs/promises";

if (process.platform !== "darwin") throw new Error("This probe requires macOS and a visible desktop.");
const root = import.meta.dir;
const artifacts = join(root, ".artifacts");
await mkdir(artifacts, { recursive: true });
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
const build = await Bun.build({ entrypoints: [join(root, "direct-app.jsx")], outdir: root,
  naming: "direct-app.js", target: "browser", define: { "process.env.NODE_ENV": '"development"' } });
if (!build.success) throw new Error(String(build.logs));
const allowed = new Set(["direct-owner.html", "direct-child.html", "direct-app.js"]);
const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch(request) {
  const name = new URL(request.url).pathname.slice(1);
  return allowed.has(name) ? new Response(Bun.file(join(root, name))) : new Response("Not found", { status: 404 });
} });
const results = [];
try {
  for (const optimization of ["-O0", "-O2"]) {
    const binary = join(artifacts, `direct-bridge${optimization}`);
    const compile = await run(["xcrun", "clang", "-fobjc-arc", optimization, "-g", "-Wall", "-Wextra", "-Werror",
      "-fsanitize=undefined", "-fno-sanitize-recover=all", "-Wno-unused-parameter", "-mmacosx-version-min=14.0",
      "-framework", "AppKit", "-framework", "WebKit", join(root, "direct-bridge.m"), "-o", binary], 30_000);
    if (compile.status !== 0 || compile.timedOut) throw new Error(JSON.stringify(compile));
    for (const origin of [`http://127.0.0.1:${server.port}`, "zapp://probe"]) {
      for (const scenario of ["round-trip", "owner-close", "owner-reload"]) {
        const url = `${origin}/direct-owner.html?scenario=${scenario}`;
        const outcome = await run([binary, root, url], 25_000);
        const result = outcome.stdout.split("\n").filter(Boolean).map(line => JSON.parse(line)).find(value => value.kind === "result");
        const pass = outcome.status === 0 && !outcome.timedOut && outcome.stderr === "" && result?.pass === true;
        results.push({ optimization, url, pass, ...outcome });
        console.log(`${pass ? "PASS" : "FAIL"} ${optimization} ${url}`);
        if (!pass) console.log(outcome.stdout, outcome.stderr);
        await Bun.write(join(artifacts, "direct-bridge-results.json"), JSON.stringify(results, null, 2));
      }
    }
  }
} finally { server.stop(true); }
if (results.some(result => !result.pass)) process.exitCode = 1;
