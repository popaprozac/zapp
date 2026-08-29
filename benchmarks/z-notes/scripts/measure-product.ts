import { existsSync } from "node:fs";
import { readFile, rm, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

interface ProductTarget {
  bundle: string;
  database: string;
  control: string;
  ready: string;
  result: string;
}

const targets: Record<string, ProductTarget> = {
  zapp: {
    bundle: resolve(
      import.meta.dir,
      "../apps/zapp/release/Z Notes Benchmark.app",
    ),
    database: "/tmp/z-notes-benchmark-zapp.sqlite3",
    control: "/tmp/z-notes-benchmark-zapp.control",
    ready: "/tmp/z-notes-benchmark-zapp.ready",
    result: "/tmp/z-notes-benchmark-zapp.result.json",
  },
  electron: {
    bundle: resolve(
      import.meta.dir,
      "../apps/electron/out/Z Notes Benchmark Electron-darwin-arm64/Z Notes Benchmark Electron.app",
    ),
    database: "/tmp/z-notes-benchmark-electron.sqlite3",
    control: "/tmp/z-notes-benchmark-electron.control",
    ready: "/tmp/z-notes-benchmark-electron.ready",
    result: "/tmp/z-notes-benchmark-electron.result.json",
  },
  electrobun: {
    bundle: resolve(
      import.meta.dir,
      "../apps/electrobun/build/stable-macos-arm64/z-notes-benchmark-electrobun.app",
    ),
    database: "/tmp/z-notes-benchmark-electrobun.sqlite3",
    control: "/tmp/z-notes-benchmark-electrobun.control",
    ready: "/tmp/z-notes-benchmark-electrobun.ready",
    result: "/tmp/z-notes-benchmark-electrobun.result.json",
  },
  tauri: {
    bundle: resolve(
      import.meta.dir,
      "../apps/tauri/src-tauri/target/release/bundle/macos/Z Notes Benchmark Tauri.app",
    ),
    database: "/tmp/z-notes-benchmark-tauri.sqlite3",
    control: "/tmp/z-notes-benchmark-tauri.control",
    ready: "/tmp/z-notes-benchmark-tauri.ready",
    result: "/tmp/z-notes-benchmark-tauri.result.json",
  },
  wails: {
    bundle: resolve(
      import.meta.dir,
      "../apps/wails/release/Z Notes Benchmark Wails.app",
    ),
    database: "/tmp/z-notes-benchmark-wails.sqlite3",
    control: "/tmp/z-notes-benchmark-wails.control",
    ready: "/tmp/z-notes-benchmark-wails.ready",
    result: "/tmp/z-notes-benchmark-wails.result.json",
  },
};

const name = process.argv[2];
const runs = Number.parseInt(process.argv[3] ?? "7", 10);
const target = targets[name];
if (!target) {
  console.error("usage: bun run bench:z-notes:product <zapp|electron|electrobun|tauri|wails> [runs]");
  process.exit(2);
}
if (!Number.isSafeInteger(runs) || runs < 1) {
  console.error("runs must be a positive integer");
  process.exit(2);
}
if (!existsSync(target.bundle)) {
  console.error(`package ${name} before measuring: ${target.bundle}`);
  process.exit(1);
}

async function command(arguments_: string[]): Promise<void> {
  const child = Bun.spawn(arguments_, { stdout: "ignore", stderr: "ignore" });
  await child.exited;
}

async function terminate(): Promise<void> {
  await command(["pkill", "-f", target.bundle]);
  const deadline = performance.now() + 3_000;
  while (performance.now() < deadline) {
    const probe = Bun.spawn(["pgrep", "-f", target.bundle], {
      stdout: "ignore",
      stderr: "ignore",
    });
    if (await probe.exited !== 0) return;
    await Bun.sleep(10);
  }
  throw new Error(`${name} did not terminate cleanly`);
}

async function cleanSample(): Promise<void> {
  await terminate();
  await Promise.all([
    rm(target.database, { force: true }),
    rm(target.ready, { force: true }),
    rm(target.result, { force: true }),
  ]);
  await writeFile(target.control, "enabled\n");
}

async function waitFor(path: string, timeoutMs: number): Promise<void> {
  const deadline = performance.now() + timeoutMs;
  while (performance.now() < deadline) {
    if (existsSync(path)) return;
    await Bun.sleep(2);
  }
  throw new Error(`${name} timed out waiting for ${path}`);
}

async function waitForReport(
  path: string,
  timeoutMs: number,
): Promise<{ iterations: number; durationMs: number }> {
  const deadline = performance.now() + timeoutMs;
  let lastError: unknown = null;
  while (performance.now() < deadline) {
    if (existsSync(path)) {
      try {
        return JSON.parse(await readFile(path, "utf8")) as {
          iterations: number;
          durationMs: number;
        };
      } catch (error) {
        lastError = error;
      }
    }
    await Bun.sleep(2);
  }
  throw new Error(`${name} timed out waiting for valid JSON at ${path}`, {
    cause: lastError,
  });
}

async function sample(): Promise<{ readyMs: number; workflowMs: number }> {
  await cleanSample();
  const started = Bun.nanoseconds();
  const launched = Bun.spawn(["open", "-g", "-n", "-a", target.bundle], {
    stdout: "ignore",
    stderr: "ignore",
  });
  if (await launched.exited !== 0) throw new Error(`could not launch ${name}`);
  await waitFor(target.ready, 20_000);
  const readyMs = Number(Bun.nanoseconds() - started) / 1_000_000;
  const report = await waitForReport(target.result, 60_000);
  if (report.iterations !== 100 || !Number.isFinite(report.durationMs)) {
    throw new Error(`${name} produced an invalid workflow report`);
  }
  await terminate();
  return { readyMs, workflowMs: report.durationMs };
}

function median(values: number[]): number {
  const ordered = values.toSorted((left, right) => left - right);
  return ordered[Math.floor(ordered.length / 2)];
}

try {
  // One untimed prime keeps dependency extraction and first-run OS work out of
  // the product sample while still resetting application data for every run.
  await sample();
  const samples = [];
  for (let index = 0; index < runs; index += 1) samples.push(await sample());
  const ready = samples.map((value) => value.readyMs);
  const workflow = samples.map((value) => value.workflowMs);
  console.log(JSON.stringify({
    label: `${name}-z-notes-product`,
    runs,
    workflow_iterations: 100,
    ready_median_ms: Number(median(ready).toFixed(3)),
    workflow_median_ms: Number(median(workflow).toFixed(3)),
    ready_samples_ms: ready.map((value) => Number(value.toFixed(3))),
    workflow_samples_ms: workflow.map((value) => Number(value.toFixed(3))),
  }));
} finally {
  await terminate();
  await Promise.all([
    rm(target.control, { force: true }),
    rm(target.ready, { force: true }),
    rm(target.result, { force: true }),
  ]);
}
