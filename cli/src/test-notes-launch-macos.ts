// Real Z Notes launch paths, including Vite ownership. The smaller startup
// fixture owns failure/ABI probes; this gate exercises the developer commands.
import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { lstat, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
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
  // Disposable files, never a developer's tracked stylesheet. Vite sees real
  // file changes through its watcher; there is no synthetic HMR sender/endpoint.
  const styleHmr = mode === "dev" && process.env.VITE_ZAPP_STYLE_SMOKE === "1";
  const hmrEntry = path.join(cwd, "style-entry.js");
  const hmrCss = path.join(cwd, "style.css");
  let hmrStage = 0;
  if (styleHmr) {
    await writeFile(hmrCss, '[data-style-probe]{--style-hmr:phase-initial}\n');
    await writeFile(hmrEntry, 'import "./style.css";\nexport const revision = "initial";\nif(import.meta.hot) import.meta.hot.accept();\n');
  }
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
    VITE_ZAPP_SVELTE_SMOKE: process.env.VITE_ZAPP_STYLE_SMOKE === "1" ? "1" : process.env.VITE_ZAPP_SVELTE_SMOKE ?? "0",
    VITE_ZAPP_STYLE_SMOKE: process.env.VITE_ZAPP_STYLE_SMOKE ?? "0",
    VITE_ZAPP_STYLE_HMR_ENTRY: styleHmr ? `/@fs${encodeURI(hmrEntry)}` : "",
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
        if (styleHmr && hmrStage === 0 && output.includes('"styleHmrPhase":"ready"')) {
          hmrStage = 1;
          await writeFile(hmrCss, '[data-style-probe]{--style-hmr:updated}\n');
        }
        if (styleHmr && hmrStage === 1 && output.includes('"styleHmrPhase":"updated"')) {
          hmrStage = 2;
          // Removing the import asks Vite to prune its actual CSS module.
          await writeFile(hmrEntry, 'export const revision = "pruned";\nif(import.meta.hot) import.meta.hot.accept();\n');
        }
      }
    } finally { reader.releaseLock(); }
    return output + decoder.decode();
  })();
  // A failed fixture edit must stop the bounded app promptly, not strand a
  // reader rejection until the native watchdog expires.
  void stdout.catch(stop);
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
    if (env.VITE_ZAPP_SVELTE_SMOKE === "1") {
      assert.ok(output.includes("Svelte inspector WebKit checks passed window=1"),
        "The primary must complete the cross-document Svelte probe");
    }
    if (env.VITE_ZAPP_STYLE_SMOKE === "1") {
      assert.ok(output.includes('"styleExperiment":"ok"'), "The private stylesheet experiment must pass");
      assert.ok(output.includes('"publicStyles":"ok"'), "The public styling/visibility integration must pass");
    }
    if (styleHmr) {
      assert.equal(hmrStage, 2, "Both real file edits must run");
      assert.ok(output.includes('"styleHmrPhase":"pruned"'), "Vite CSS HMR and import pruning must reach the children");
    }
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
    try {
      await Promise.all([stdout, stderr]);
    } finally {
      await rm(cwd, { recursive: true, force: true });
      await rm(path.join(homedir(), "Library/Application Support", identifier), { recursive: true, force: true });
    }
    // Endpoint cleanup is asserted above; do not mask a runtime leak here.
  }
}
