// Optional developer diagnostic: timestamp the real Z Notes smoke output.
// These are pipe-observation intervals, not per-function profiler samples.
import { mkdir, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { signalProcessTree } from "../../cli/src/bounded-process";

const root = resolve(import.meta.dir, "../..");
const development = process.argv.includes("--dev");
if (process.platform !== "darwin"
  || process.argv.slice(2).some((argument) => argument !== "--dev")) {
  throw new Error("Usage: bun spikes/window-resize/trace-shutdown.ts [--dev] (opens bounded smoke windows)");
}
const started = performance.now();
const observations: { milliseconds: number; stream: string; line: string }[] = [];
const phases: Record<string, number> = {};
const child = Bun.spawn([
  process.execPath,
  development ? "spikes/z-notes/dev.ts" : "spikes/z-notes/run.ts",
  "--smoke",
], { cwd: root, detached: true, stdout: "pipe", stderr: "pipe" });
const stop = () => signalProcessTree(child, "SIGKILL");
let timedOut = false;
const deadline = setTimeout(() => { timedOut = true; stop(); }, 240_000);
process.on("SIGINT", stop);
process.on("SIGTERM", stop);

function observe(stream: string, line: string) {
  const milliseconds = performance.now() - started;
  observations.push({ milliseconds, stream, line });
  let phase: string | undefined;
  if (/^window .* closed$/.test(line)) phase = "observedWindowClosed";
  else if (line === "application worker joined after cancellation") phase = "observedWorkerJoined";
  else if (line === "Z Notes: notes service stopped") phase = "observedServiceStopped";
  else if (line === "Z Notes dev smoke released Vite port 5173") phase = "vitePortReleased";
  if (phase) {
    phases[phase] = milliseconds;
    console.log(`${milliseconds.toFixed(1)}ms ${phase}`);
  } else if (line.startsWith("built ") || line.startsWith("[zapp]")) console.log(line);
}

async function read(stream: ReadableStream<Uint8Array>, name: string) {
  const decoder = new TextDecoder();
  const reader = stream.getReader();
  let pending = "";
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      pending += decoder.decode(value, { stream: true });
      let newline: number;
      while ((newline = pending.indexOf("\n")) >= 0) {
        observe(name, pending.slice(0, newline));
        pending = pending.slice(newline + 1);
      }
    }
    pending += decoder.decode();
    if (pending) observe(name, pending);
  } finally {
    reader.releaseLock();
  }
}

try {
  await Promise.all([read(child.stdout, "stdout"), read(child.stderr, "stderr")]);
  const status = await child.exited;
  phases.runnerExited = performance.now() - started;
  const elapsed = (from: string, to: string) =>
    phases[from] === undefined || phases[to] === undefined ? null : phases[to]! - phases[from]!;
  const intervals = {
    closeLogToWorkerJoinLog: elapsed("observedWindowClosed", "observedWorkerJoined"),
    workerJoinLogToServiceStopLog: elapsed("observedWorkerJoined", "observedServiceStopped"),
    serviceStopLogToRunnerExit: elapsed("observedServiceStopped", "runnerExited"),
  };
  const directory = resolve(root, ".zapp/window-resize");
  await mkdir(directory, { recursive: true });
  const report = resolve(directory, `shutdown-${Date.now()}.json`);
  await writeFile(report, JSON.stringify({ development, status, timedOut, phases, intervals, observations }, null, 2));
  console.log(JSON.stringify(intervals, null, 2));
  console.log(`Trace: ${report}`);
  if (status !== 0) console.error(observations.slice(-20).map((entry) => entry.line).join("\n"));
  process.exitCode = status === 0 && !timedOut ? 0 : 1;
} finally {
  clearTimeout(deadline);
  process.off("SIGINT", stop);
  process.off("SIGTERM", stop);
  if (child.exitCode === null) stop();
}
