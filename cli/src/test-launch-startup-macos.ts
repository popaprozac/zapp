// The production listener, typed readiness channel, and main delivery owner.
// Random test identities only; every child and socket has a deadline.
import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { copyFile, lstat, mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { createConnection, type Socket } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { runBoundedCommand, signalProcessTree, terminateProcessTree } from "./bounded-process";

if (process.platform !== "darwin") throw new Error("Launch startup regression requires macOS");
const repo = path.resolve(import.meta.dir, "../..");
const compiler = process.env.Z_SOURCE_ROOT ?? path.resolve(repo, "../z-lang");
const root = await mkdtemp(path.join(tmpdir(), "zapp-launch-startup-"));
const binary = path.join(root, "build/startup-probe");
const children = new Set<ReturnType<typeof Bun.spawn>>();
const sockets = new Set<Socket>();
const paths = new Set<string>();

async function command(args: string[], timeoutMs = 15_000) {
  const result = await runBoundedCommand(args, { cwd: root, timeoutMs });
  assert.equal(result.timedOut, false, `Timed out: ${args.join(" ")}`);
  assert.equal(result.status, 0, result.stderr || result.stdout);
  return result;
}

function start(id: string, mode: string) {
  const args = mode === "secondary" ? [id, mode, "", "draft with spaces", "資料"] : [id, mode];
  const child = Bun.spawn([binary, ...args], { cwd: root, detached: true, stdout: "pipe", stderr: "pipe" });
  children.add(child);
  const watchdog = setTimeout(() => signalProcessTree(child, "SIGKILL"), 12_000);
  const stderr = new Response(child.stderr).text();
  let resolveReady!: (value: string) => void;
  let rejectReady!: (error: Error) => void;
  const ready = new Promise<string>((resolve, reject) => { resolveReady = resolve; rejectReady = reject; });
  const stdout = (async () => {
    const reader = child.stdout.getReader();
    const decoder = new TextDecoder();
    let output = "";
    try {
      while (true) {
        const next = await reader.read();
        if (next.done) break;
        output += decoder.decode(next.value, { stream: true });
        if (output.includes("\n")) resolveReady(output.split("\n")[0]!);
      }
      if (!output.includes("\n")) rejectReady(new Error(`Startup exited before readiness: ${await stderr}`));
      return output;
    } finally { reader.releaseLock(); }
  })();
  const exited = child.exited.finally(() => { clearTimeout(watchdog); children.delete(child); });
  return { ready, stdout, stderr, exited };
}

async function partialRequest(socketPath: string) {
  await new Promise<void>((resolve, reject) => {
    const socket = createConnection(socketPath);
    sockets.add(socket);
    const deadline = setTimeout(() => socket.destroy(new Error("partial request deadline")), 3_000);
    socket.on("error", reject);
    socket.on("data", () => reject(new Error("partial request was acknowledged")));
    socket.on("close", () => { clearTimeout(deadline); sockets.delete(socket); resolve(); });
    socket.on("connect", () => socket.write(Buffer.from([0])));
  });
}

try {
  const files = [
    "framework/platform/macos/instance-lease.zs", "framework/platform/macos/launch-socket.zs",
    "framework/platform/macos/instance-transport.zs", "framework/platform/macos/launch-listener.zs",
    "framework/platform/macos/launch-delivery.zs", "framework/activation-inbox.zs",
    "framework/application-launch.zs", "framework/application-events.zs", "framework/application-activation.zs",
    "framework/events.zs", "tests/application-launch-startup-smoke.zs",
  ];
  for (const file of files) {
    const target = path.join(root, file);
    await mkdir(path.dirname(target), { recursive: true });
    await copyFile(path.join(repo, "native/z", file), target);
  }
  await writeFile(path.join(root, "z.json"), JSON.stringify({
    package: { name: "zapp-launch-startup-regression", version: "0.1.0" },
    target: { name: "startup-probe", entry: "tests/application-launch-startup-smoke.zs", platform: "macos", minimumVersion: "14.0" },
  }));
  const userTemp = (await command(["getconf", "DARWIN_USER_TEMP_DIR"])).stdout.trim();
  for (const frontend of [
    { name: "Stage 0", args: [process.execPath, path.join(compiler, "compiler/src/cli.ts")] },
    { name: "native", args: [path.join(compiler, ".z-cache/bootstrap/z")] },
  ]) {
    const build = await runBoundedCommand([...frontend.args, "build", root], { cwd: root, timeoutMs: 180_000 });
    assert.equal(build.timedOut, false, `${frontend.name} startup build timed out`);
    assert.equal(build.status, 0, build.stderr || build.stdout);
    if (process.env.ZAPP_LAUNCH_UBSAN === "1") {
      await command(["clang", "-x", "objective-c", "-std=c11", "-fobjc-arc", "-O1", "-g", "-pthread",
        "-Wall", "-Wextra", "-Werror", "-mmacosx-version-min=14.0", "-fsanitize=undefined", "-fno-sanitize-recover=all",
        "-framework", "Foundation", "-framework", "CoreFoundation", path.join(root, ".z-cache/build/startup-probe.m"), "-o", binary], 60_000);
    }
    for (const mode of ["normal", "idle", "partial", "startup-failure"]) {
      const id = `com.zapp.startup-probe.${randomUUID()}`;
      const key = createHash("sha256").update(id).digest("hex");
      const socket = `/private/tmp/zapp-launch-${process.geteuid!()}/${key}`;
      paths.add(socket);
      paths.add(path.join(userTemp, "zapp-instance-v1", `${key}.lock`));
      if (mode === "startup-failure") {
        await mkdir(path.dirname(socket), { recursive: true, mode: 0o700 });
        await symlink(path.join(root, "missing-target"), socket);
      }
      const primary = start(id, mode);
      const ready = mode === "startup-failure" ? "failed" : "ready";
      assert.equal(await primary.ready, ready);
      const began = performance.now();
      if (mode === "normal") {
        const secondary = start(id, "secondary");
        assert.equal(await secondary.ready, "forwarded");
        assert.equal(await secondary.exited, 0, `${await secondary.stdout}\n${await secondary.stderr}`);
        assert.equal(await secondary.stdout, "forwarded\nlistener joined\ndelivery joined\ndelivered 0\n");
        assert.equal(await secondary.stderr, "");
      } else if (mode === "partial") await partialRequest(socket);
      assert.equal(await primary.exited, 0, `${frontend.name}/${mode}\n${await primary.stdout}\n${await primary.stderr}`);
      assert.equal(await primary.stdout, `${ready}\nlistener joined\ndelivery joined\ndelivered ${mode === "normal" ? 1 : 0}\n`);
      assert.equal(await primary.stderr, "");
      assert.ok(performance.now() - began < 4_000, `${mode} exceeded bounded shutdown`);
      if (mode === "startup-failure") assert.equal((await lstat(socket)).isSymbolicLink(), true);
      else await assert.rejects(lstat(socket), { code: "ENOENT" });
      console.log(`${frontend.name}: ${mode} passed`);
    }
  }
} finally {
  for (const socket of sockets) socket.destroy();
  await Promise.all([...children].map((child) => terminateProcessTree(child)));
  for (const file of paths) await rm(file, { force: true });
  await rm(root, { recursive: true, force: true });
}
