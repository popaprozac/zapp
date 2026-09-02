import { resolve } from "node:path";
import { compileNative } from "../../cli/src/native";
import { prepareZFrontendServices } from "../../cli/src/native-z";
import {
  createConfigContext,
  loadConfig,
} from "../../cli/src/config";

const spike = import.meta.dir;
const repository = resolve(spike, "../..");
const output = resolve(spike, "build", "zapp-z-webview");

async function run(
  command: string[],
  env?: Record<string, string | undefined>,
  workingDirectory = repository,
): Promise<void> {
  const child = Bun.spawn(command, {
    cwd: workingDirectory,
    env,
    stdout: "inherit",
    stderr: "inherit",
  });
  const status = await child.exited;
  if (status !== 0) {
    throw new Error(`${command[0]} exited with status ${status}`);
  }
}

async function runWorkerSmoke(command: string[]): Promise<void> {
  const child = Bun.spawn(command, {
    cwd: repository,
    env: process.env,
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr, status] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  process.stdout.write(stdout);
  process.stderr.write(stderr);
  if (status !== 0) {
    throw new Error(`${command[0]} exited with status ${status}`);
  }
  if (!stdout.includes("sent pong")) {
    throw new Error(
      "configured application worker did not reply on channel pong",
    );
  }
  if (!stdout.includes("sent service")) {
    throw new Error(
      "configured application worker did not invoke the Z health service directly",
    );
  }
  if (!stdout.includes("sent async-service")) {
    throw new Error(
      "configured application worker did not await a suspended Z service",
    );
  }
  if (!stdout.includes("sent async-cancelled")) {
    throw new Error(
      "configured application worker did not cancel a suspended Z service",
    );
  }
  if (!stdout.includes("sent denied")) {
    throw new Error(
      "configured application worker did not receive a typed capability denial",
    );
  }
  if (
    stdout.includes("sent denial-missing")
    || stdout.includes("sent denial-wrong-error")
    || stdout.includes("sent async-cancellation-missing")
    || stdout.includes("sent async-cancellation-wrong-error")
  ) {
    throw new Error(
      "configured application worker did not preserve service capability safety",
    );
  }
}

function median(values: number[]): number {
  const ordered = [...values].sort((left, right) => left - right);
  return ordered[Math.floor(ordered.length / 2)] ?? 0;
}

function range(values: number[]): string {
  return `${Math.min(...values)}-${Math.max(...values)}`;
}

async function runWorkerBenchmark(command: string[]): Promise<void> {
  const child = Bun.spawn(command, {
    cwd: repository,
    env: process.env,
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr, status] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  process.stdout.write(stdout);
  process.stderr.write(stderr);
  if (status !== 0) {
    throw new Error(`${command[0]} exited with status ${status}`);
  }
  const direct: number[] = [];
  const publicApi: number[] = [];
  const pattern = /sent benchmark-sample-\d+-direct-(\d+)-public-(\d+)/g;
  for (const match of stdout.matchAll(pattern)) {
    direct.push(Number(match[1]));
    publicApi.push(Number(match[2]));
  }
  if (
    direct.length !== 5
    || publicApi.length !== 5
    || !stdout.includes("sent benchmark-complete")
    || stdout.includes("sent benchmark-error")
  ) {
    throw new Error("configured application worker benchmark did not complete");
  }
  console.log("\nZJS direct Z service benchmark (median of 5 warmed samples)");
  console.log(
    `  direct host: ${median(direct)} ns/call (range ${range(direct)})`,
  );
  console.log(
    `  generated Promise API: ${median(publicApi)} ns/call `
    + `(range ${range(publicApi)})`,
  );
}

const smoke = process.argv.includes("--smoke");
const workerSmoke = process.argv.includes("--worker-smoke");
const workerBenchmark = process.argv.includes("--worker-benchmark");
const originalWorkerSmoke = process.env.ZAPP_APPLICATION_WORKER_SMOKE;
const originalWorkerBenchmark = process.env.ZAPP_APPLICATION_WORKER_BENCHMARK;
if (workerSmoke || workerBenchmark) {
  process.env.ZAPP_APPLICATION_WORKER_SMOKE = "1";
}
if (workerBenchmark) process.env.ZAPP_APPLICATION_WORKER_BENCHMARK = "1";
const config = await loadConfig(
  spike,
  createConfigContext(spike, "build", "macos"),
);

const originalLanguage = process.env.ZAPP_NATIVE_LANG;
const originalHost = process.env.ZAPP_Z_HOST;
const originalSmokeSupport = process.env.ZAPP_Z_DESKTOP_SMOKE_SUPPORT;
let compiled = false;
process.env.ZAPP_NATIVE_LANG = "z";
process.env.ZAPP_Z_HOST = "desktop";
if (smoke) process.env.ZAPP_Z_DESKTOP_SMOKE_SUPPORT = "1";
try {
  const preparedZServices = await prepareZFrontendServices({
    root: spike,
    nativeDir: resolve(repository, "native"),
  });
  await run(
    ["bunx", "vite", "build"],
    { ...process.env, ZAPP_PROJECT_ROOT: spike },
    spike,
  );
  await compileNative({
    root: spike,
    buildFile: "",
    buildConfigFile: "",
    nativeDir: resolve(repository, "native"),
    output,
    optimize: true,
    target: "macos",
    config,
    preparedZServices,
  });
  compiled = true;
} finally {
  if (originalLanguage === undefined) delete process.env.ZAPP_NATIVE_LANG;
  else process.env.ZAPP_NATIVE_LANG = originalLanguage;
  if (originalHost === undefined) delete process.env.ZAPP_Z_HOST;
  else process.env.ZAPP_Z_HOST = originalHost;
  if (originalSmokeSupport === undefined) {
    delete process.env.ZAPP_Z_DESKTOP_SMOKE_SUPPORT;
  } else {
    process.env.ZAPP_Z_DESKTOP_SMOKE_SUPPORT = originalSmokeSupport;
  }
  if (originalWorkerSmoke === undefined) {
    delete process.env.ZAPP_APPLICATION_WORKER_SMOKE;
  } else {
    process.env.ZAPP_APPLICATION_WORKER_SMOKE = originalWorkerSmoke;
  }
  if (originalWorkerBenchmark === undefined) {
    delete process.env.ZAPP_APPLICATION_WORKER_BENCHMARK;
  } else {
    process.env.ZAPP_APPLICATION_WORKER_BENCHMARK = originalWorkerBenchmark;
  }
}

if (workerBenchmark) await runWorkerBenchmark([output]);
else if (workerSmoke) await runWorkerSmoke([output]);
else await run([output], process.env);
