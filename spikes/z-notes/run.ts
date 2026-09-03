import { rmSync } from "node:fs";
import { homedir } from "node:os";
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
  if (!stdout.includes("worker manager sent ping")) {
    throw new Error(
      "native Z WorkerManager did not dispatch through its configured handle",
    );
  }
  if (!stdout.includes("sent manager-pong")) {
    throw new Error(
      "configured application worker did not reply to WorkerManager.send",
    );
  }
  if (
    !stdout.includes(
      "worker message manager-pong: worker-manager-smoke",
    )
  ) {
    throw new Error(
      "native Z ApplicationWorker.messages did not publish the worker response",
    );
  }
  const progress = stdout.match(
    /worker message progress: \{"requestId":"native-smoke","completed":1,"total":(\d+)/,
  );
  const completion = stdout.match(
    /worker message complete: \{"requestId":"native-smoke","total":(\d+),"active":(\d+)/,
  );
  if (
    !stdout.includes("worker manager requested note index")
    || !stdout.includes("sent started")
    || !stdout.includes("sent complete")
    || progress === null
    || completion === null
    || Number(progress[1]) < 1
    || completion[1] !== progress[1]
    || completion[2] !== progress[1]
  ) {
    throw new Error(
      "configured application worker did not index Z-owned notes end to end",
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

async function captureRun(command: string[]): Promise<string> {
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
  return stdout;
}

async function runPersistenceSmoke(command: string[]): Promise<void> {
  const first = await captureRun(command);
  const second = await captureRun(command);
  if (
    !first.includes(
      'worker message complete: {"requestId":"native-smoke","total":1,"active":1',
    )
    || !first.includes('payload={"id":"2","title":"WebView note"')
    || !first.includes('payload={"id":"3","title":"WebView note"')
  ) {
    throw new Error("first persistence launch did not seed and store notes");
  }
  if (
    !second.includes(
      'worker message complete: {"requestId":"native-smoke","total":3,"active":3',
    )
    || !second.includes('payload={"id":"4","title":"WebView note"')
    || !second.includes('payload={"id":"5","title":"WebView note"')
  ) {
    throw new Error("second persistence launch did not reload and extend notes");
  }
  console.log("Z Notes persistence smoke reloaded IDs 1-3 and created IDs 4-5");
}

async function runWorkerRestartSmoke(command: string[]): Promise<void> {
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
  const failures = stderr.match(/restartProbe\.mjs incarnation \d+ failed/g) ?? [];
  if (
    failures.length !== 3
    || !stderr.includes("restarting as incarnation 2 (retry 1/2 in 60000ms)")
    || !stderr.includes("restarting as incarnation 3 (retry 2/2 in 60000ms)")
    || !stderr.includes("restartProbe.mjs gave up after 2 retries")
  ) {
    throw new Error("configured application worker did not enforce its restart cap");
  }
  if (
    !stdout.includes("worker restartProbe restarting after incarnation 1 (retry 1/2)")
    || !stdout.includes("worker restartProbe restarting after incarnation 2 (retry 2/2)")
    || !stdout.includes("worker restartProbe failed after 2 retries")
  ) {
    throw new Error(
      "native Z WorkerManager did not publish restart lifecycle events",
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
const persistenceSmoke = process.argv.includes("--persistence-smoke");
const workerSmoke = process.argv.includes("--worker-smoke");
const workerRestartSmoke = process.argv.includes("--worker-restart-smoke");
const workerBenchmark = process.argv.includes("--worker-benchmark");
const originalWorkerSmoke = process.env.ZAPP_APPLICATION_WORKER_SMOKE;
const originalWorkerRestartSmoke =
  process.env.ZAPP_APPLICATION_WORKER_RESTART_SMOKE;
const originalWorkerBenchmark = process.env.ZAPP_APPLICATION_WORKER_BENCHMARK;
const originalApplicationIdentifier = process.env.ZAPP_Z_NOTES_IDENTIFIER;
if (persistenceSmoke) {
  const identifier = "com.zapp.z-notes.persistence-smoke";
  process.env.ZAPP_Z_NOTES_IDENTIFIER = identifier;
  rmSync(
    resolve(homedir(), "Library", "Application Support", identifier),
    { recursive: true, force: true },
  );
}
if (workerSmoke || workerBenchmark) {
  process.env.ZAPP_APPLICATION_WORKER_SMOKE = "1";
}
if (workerBenchmark) process.env.ZAPP_APPLICATION_WORKER_BENCHMARK = "1";
if (workerRestartSmoke) {
  process.env.ZAPP_APPLICATION_WORKER_RESTART_SMOKE = "1";
}
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
    config,
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
  if (originalWorkerRestartSmoke === undefined) {
    delete process.env.ZAPP_APPLICATION_WORKER_RESTART_SMOKE;
  } else {
    process.env.ZAPP_APPLICATION_WORKER_RESTART_SMOKE =
      originalWorkerRestartSmoke;
  }
  if (originalApplicationIdentifier === undefined) {
    delete process.env.ZAPP_Z_NOTES_IDENTIFIER;
  } else {
    process.env.ZAPP_Z_NOTES_IDENTIFIER = originalApplicationIdentifier;
  }
}

if (persistenceSmoke) await runPersistenceSmoke([output]);
else if (workerBenchmark) await runWorkerBenchmark([output]);
else if (workerRestartSmoke) await runWorkerRestartSmoke([output]);
else if (workerSmoke) await runWorkerSmoke([output]);
else await run([output], process.env);
