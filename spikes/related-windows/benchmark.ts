import { join } from "node:path";
import { mkdir } from "node:fs/promises";
import type { BenchmarkResult, BenchmarkMode, RecordedBenchmark } from "./types";

if (process.platform !== "darwin") throw new Error("This platform benchmark requires macOS and a visible desktop.");
const root = import.meta.dir;
const artifacts = join(root, ".artifacts");
await mkdir(artifacts, { recursive: true });
const runCount = Number(process.env.BENCH_RUNS || "5");
if (!Number.isInteger(runCount) || runCount < 1 || runCount > 20) throw new Error("BENCH_RUNS must be an integer from 1 to 20.");
if (await Bun.file(join(artifacts, "benchmark-results.json")).exists()) {
  await Bun.write(join(artifacts, `benchmark-results-before-${Date.now()}.json`), Bun.file(join(artifacts, "benchmark-results.json")));
}
async function run(command: string[], timeoutMs: number) {
  const child = Bun.spawn(command, { cwd: root, detached: true, stdout: "pipe", stderr: "pipe" });
  let timedOut = false;
  const kill = () => { try { process.kill(-child.pid, "SIGKILL"); } catch { child.kill("SIGKILL"); } };
  const interrupt = () => { kill(); process.exit(130); };
  process.once("SIGINT", interrupt); process.once("SIGTERM", interrupt);
  const timer = setTimeout(() => { timedOut = true; kill(); }, timeoutMs);
  try {
    const [status, stdout, stderr] = await Promise.all([
      child.exited, new Response(child.stdout).text(), new Response(child.stderr).text(),
    ]);
    if (status !== 0 || timedOut) throw new Error(JSON.stringify({ command, status, timedOut, stdout, stderr }));
    return { stdout, stderr };
  } finally {
    clearTimeout(timer); process.off("SIGINT", interrupt); process.off("SIGTERM", interrupt);
  }
}
const compile = await run(["xcrun", "clang", "-fobjc-arc", "-O2", "-DNDEBUG", "-Wall", "-Wextra", "-Werror",
  "-Wno-unused-parameter", "-mmacosx-version-min=14.0", "-framework", "AppKit", "-framework", "WebKit",
  join(root, "benchmark.m"), "-o", join(root, "benchmark")], 30_000);
const build = await Bun.build({ entrypoints: [join(root, "bench.jsx")], outdir: root,
  naming: "bench.js", target: "browser", minify: true, define: { "process.env.NODE_ENV": '"production"' } });
if (!build.success) throw new Error(String(build.logs));
const allowed = new Set(["bench-owner.html", "bench-related.html", "bench-independent.html", "bench.js", "related-child.js", "bench.css"]);
const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch(request) {
  const name = new URL(request.url).pathname.slice(1);
  if (!allowed.has(name)) return new Response("Not found", { status: 404 });
  return new Response(Bun.file(join(root, name)), { headers: { "Cache-Control": "public, max-age=3600" } });
} });
const results: RecordedBenchmark[] = [];
try {
  for (let round = 0; round < runCount; round++) {
    const origins = round % 2 ? ["zapp://probe", `http://127.0.0.1:${server.port}`] : [`http://127.0.0.1:${server.port}`, "zapp://probe"];
    for (const origin of origins) {
      const modes: BenchmarkMode[] = ["related", "related-root", "independent"];
      const rotation = round % modes.length;
      const order = [...modes.slice(rotation), ...modes.slice(0, rotation)];
      if (round % 2) order.reverse();
      for (const mode of order) {
        const url = `${origin}/bench-owner.html?mode=${mode}`;
        const start = performance.now();
        const outcome = await run([join(root, "benchmark"), root, url], 35_000);
        const value = outcome.stdout.split("\n").filter(Boolean).map(line => JSON.parse(line) as BenchmarkResult).find(v => v.kind === "result");
        if (!value?.pass) throw new Error(outcome.stdout);
        results.push({ round, processMs: performance.now() - start, ...value, stderr: outcome.stderr });
        console.log(`PASS round=${round} ${origin.split(":")[0]} ${mode} (${Math.round(performance.now() - start)} ms)`);
        await Bun.write(join(artifacts, "benchmark-results.json"), JSON.stringify(results, null, 2));
      }
    }
  }
} finally { server.stop(true); }
const quantile = (values: number[], q: number) => [...values].sort((a, b) => a - b)[Math.ceil((values.length - 1) * q)];
const summary = [];
for (const origin of ["http:", "zapp:"]) for (const mode of ["related", "related-root", "independent"]) {
  const runs = results.filter(r => r.origin === origin && r.mode === mode);
  const stats = (values: number[]) => ({ n: values.length, p50: quantile(values, .5), p95: quantile(values, .95) });
  summary.push({ origin, mode, runs: runs.length,
    firstChildTwoFramesMs: stats(runs.map(r => r.startup[0].twoFramesMs)),
    laterChildTwoFramesMs: stats(runs.flatMap(r => r.startup.slice(1).map(s => s.twoFramesMs))),
    childScriptLoadInitMs: stats(runs.flatMap(r => r.startup.map(s => s.scriptLoadInitMs))),
    nativeCreationMs: stats(runs.flatMap(r => r.nativeCreationMs)),
    deltaCompletionMs: stats(runs.flatMap(r => r.delta.samples.map(s => s.elapsedMs))),
    deltaRunMeanMs: stats(runs.map(r => r.delta.meanCompletionMs)),
    coalesced32CompletionMs: stats(runs.flatMap(r => r.coalesced32.samples.map(s => s.elapsedMs))),
    coalesced32RunMeanMs: stats(runs.map(r => r.coalesced32.meanCompletionMs)),
    updateTwoFramesMs: stats(runs.flatMap(r => r.frames.samples.map(s => s.elapsedMs))),
  });
}
const report = { date: new Date().toISOString(), runCount,
  productionBundleBytes: Bun.file(join(root, "bench.js")).size,
  relatedChildHelperBytes: Bun.file(join(root, "related-child.js")).size,
  compileStderr: compile.stderr, summary };
await Bun.write(join(artifacts, "benchmark-summary.json"), JSON.stringify(report, null, 2));
console.log(JSON.stringify(report, null, 2));
