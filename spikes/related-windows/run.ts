import { join } from "node:path";
import { mkdir } from "node:fs/promises";

async function runBoundedCommand(command: string[], { cwd, timeoutMs }: { cwd: string; timeoutMs: number }) {
  const child = Bun.spawn(command, { cwd, detached: true, stdout: "pipe", stderr: "pipe" });
  let timedOut = false;
  const kill = () => {
    try { process.kill(-child.pid, "SIGKILL"); }
    catch { try { child.kill("SIGKILL"); } catch {} }
  };
  const interrupted = () => { kill(); process.exit(130); };
  process.once("SIGINT", interrupted);
  process.once("SIGTERM", interrupted);
  const timer = setTimeout(() => { timedOut = true; kill(); }, timeoutMs);
  try {
    const [status, stdout, stderr] = await Promise.all([
      child.exited, new Response(child.stdout).text(), new Response(child.stderr).text(),
    ]);
    return { status, stdout, stderr, timedOut };
  } finally {
    clearTimeout(timer);
    process.off("SIGINT", interrupted);
    process.off("SIGTERM", interrupted);
  }
}

if (process.platform !== "darwin") throw new Error("This platform probe requires macOS and a visible desktop.");
const root = import.meta.dir;
const artifacts = join(root, ".artifacts");
await mkdir(artifacts, { recursive: true });
const compile = await runBoundedCommand([
  "xcrun", "clang", "-fobjc-arc", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
  "-fsanitize=undefined", "-fno-sanitize-recover=all",
  "-Wno-unused-parameter", "-mmacosx-version-min=14.0",
  "-framework", "AppKit", "-framework", "WebKit", join(root, "probe.m"), "-o", join(root, "probe"),
], { cwd: root, timeoutMs: 30_000 });
if (compile.status !== 0) throw new Error(compile.stderr);
const build = await Bun.build({
  entrypoints: [join(root, "app.jsx")], outdir: root, naming: "app.js",
  target: "browser", define: { "process.env.NODE_ENV": '"development"' },
});
if (!build.success) throw new Error(String(build.logs));
const server = Bun.serve({
  hostname: "127.0.0.1", port: 0,
  fetch(request) {
    const name = new URL(request.url).pathname.slice(1);
    if (!["index.html", "app.js", "child.html"].includes(name)) return new Response("Not found", { status: 404 });
    return new Response(Bun.file(join(root, name)));
  },
});
const results = [];
try {
  for (const base of [`http://127.0.0.1:${server.port}`, "zapp://probe"]) {
    for (const child of ["blank", "url", "cross-origin"]) {
      const url = `${base}/index.html?child=${child}`;
      const outcome = await runBoundedCommand([join(root, "probe"), root, url], { cwd: root, timeoutMs: 20_000 });
      const value = { url, ...outcome };
      results.push(value);
      console.log(`${outcome.status === 0 && !outcome.timedOut ? "PASS" : "FAIL"} ${url}`);
      if (outcome.status !== 0) console.log(outcome.stdout, outcome.stderr);
    }
  }
} finally {
  server.stop(true);
}
await Bun.write(join(artifacts, "feasibility-results.json"), JSON.stringify(results, null, 2));
if (results.some(value => value.status !== 0 || value.timedOut)) process.exitCode = 1;
