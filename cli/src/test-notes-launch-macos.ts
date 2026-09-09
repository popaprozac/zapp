// Real Z Notes launch paths, including Vite ownership. The smaller startup
// fixture owns failure/ABI probes; this gate exercises the developer commands.
import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { lstat, mkdir, mkdtemp, rm } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";
import { runBoundedCommand, signalProcessTree, terminateProcessTree } from "./bounded-process";

if (process.platform !== "darwin") throw new Error("Z Notes launch regression requires macOS");
const repo = path.resolve(import.meta.dir, "../..");
const notes = path.join(repo, "spikes/z-notes");
const selected = process.argv[2];
if (selected !== undefined && selected !== "packaged" && selected !== "dev") {
  throw new Error("usage: bun cli/src/test-notes-launch-macos.ts [packaged|dev]");
}

for (const mode of selected ? [selected] : ["packaged", "dev"]) {
  // Fail without touching a developer's Vite process or interactive bundle.
  if (mode === "dev") {
    const probe = Bun.serve({ hostname: "127.0.0.1", port: 5173, fetch: () => new Response("probe") });
    probe.stop(true);
  }
  await mkdir(path.join(repo, ".zapp"), { recursive: true });
  const cwd = await mkdtemp(path.join(repo, ".zapp/notes-launch-"));
  const identifier = `com.zapp.z-notes.launch-smoke.${randomUUID()}`;
  const key = createHash("sha256").update(identifier).digest("hex");
  const socket = `/private/tmp/zapp-launch-${process.geteuid!()}/${key}`;
  const binary = path.join(notes, ".zapp/smoke/bin/Z Notes.app/Contents/MacOS",
    mode === "dev" ? "z-notes" : "zapp-z-webview");
  const env = {
    ...process.env,
    ZAPP_Z_NOTES_IDENTIFIER: identifier,
    ZAPP_NATIVE_LANG: "z",
    ZAPP_APPLICATION_WORKER_SMOKE: "1",
  };
  const primary = Bun.spawn([process.execPath, path.join(notes, mode === "dev" ? "dev.ts" : "run.ts"), "--smoke"], {
    cwd: repo, env, detached: true, stdout: "pipe", stderr: "pipe",
  });
  let timedOut = false;
  let forcedStop: ReturnType<typeof setTimeout> | undefined;
  const stop = () => {
    signalProcessTree(primary);
    forcedStop ??= setTimeout(() => signalProcessTree(primary, "SIGKILL"), 5_000);
  };
  const timer = setTimeout(() => { timedOut = true; stop(); }, 240_000);
  process.once("SIGINT", stop);
  process.once("SIGTERM", stop);
  let ready!: () => void;
  const started = new Promise<void>((resolve) => { ready = resolve; });
  const stdout = (async () => {
    const decoder = new TextDecoder();
    let output = "";
    const reader = primary.stdout.getReader();
    try {
      while (true) {
        const chunk = await reader.read();
        if (chunk.done) break;
        process.stdout.write(chunk.value);
        output += decoder.decode(chunk.value, { stream: true });
        if (output.includes("notes service started\n")) ready();
      }
    } finally { reader.releaseLock(); }
    return output + decoder.decode();
  })();
  const stderr = (async () => {
    const decoder = new TextDecoder();
    let output = "";
    const reader = primary.stderr.getReader();
    try {
      while (true) {
        const chunk = await reader.read();
        if (chunk.done) break;
        process.stderr.write(chunk.value);
        output += decoder.decode(chunk.value, { stream: true });
      }
    } finally { reader.releaseLock(); }
    return output + decoder.decode();
  })();
  try {
    await Promise.race([started, primary.exited.then(async () => {
      throw new Error(`Z Notes ${mode} exited before startup: ${await stdout}\n${await stderr}`);
    })]);
    const secondary = await runBoundedCommand([binary, "", "draft with spaces", "資料", "znotes://notes/1"], {
      cwd, env, timeoutMs: 15_000,
    });
    assert.equal(secondary.timedOut, false, "Secondary did not finish forwarding");
    assert.equal(secondary.status, 0, secondary.stderr || secondary.stdout);
    assert.equal(secondary.stdout, "", "Secondary must not start services, workers, or a WebView");
    assert.equal(await primary.exited, 0, `Z Notes ${mode} failed: ${await stderr}`);
    assert.equal(timedOut, false, `Z Notes ${mode} exceeded its build/run deadline`);
    const output = await stdout;
    assert.equal(output.split("notes service started\n").length - 1, 1, output);
    assert.equal(output.split("notes service stopped\n").length - 1, 1, output);
    assert.equal(output.split("Z Notes handled a secondary launch (4 arguments)\n").length - 1, 1, output);
    assert.ok(output.includes("visible WebView round trip"), "The primary must complete its WebView smoke");
    assert.ok(output.includes("sent async-service"), "The primary must complete a suspended worker service call");
    assert.ok(!output.includes("deep link opened note"), "URL-looking arguments must not become implicit URL events");
    if (mode === "dev") assert.ok(output.includes("Z Notes dev smoke released Vite port 5173"), output);
    await assert.rejects(lstat(socket), { code: "ENOENT" });
    console.log(`Z Notes ${mode}: one primary, one forwarded launch, worker/WebView checks and ordered shutdown passed`);
  } finally {
    clearTimeout(timer);
    if (forcedStop) clearTimeout(forcedStop);
    process.removeListener("SIGINT", stop);
    process.removeListener("SIGTERM", stop);
    await terminateProcessTree(primary, 5_000);
    await Promise.all([stdout, stderr]);
    await rm(cwd, { recursive: true, force: true });
    await rm(path.join(homedir(), "Library/Application Support", identifier), { recursive: true, force: true });
    // Endpoint cleanup is asserted above; do not mask a runtime leak here.
  }
}
