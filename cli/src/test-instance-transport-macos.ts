// Bounded real socket/process regression. No interactive bundles or identities.
import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { chmod, copyFile, lstat, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { createConnection, createServer, type Socket } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { runBoundedCommand, signalProcessTree, terminateProcessTree } from "./bounded-process";

if (process.platform !== "darwin") throw new Error("Launch transport regression requires macOS");
const repo = path.resolve(import.meta.dir, "../..");
const compiler = process.env.Z_SOURCE_ROOT ?? path.resolve(repo, "../z-lang");
const root = await mkdtemp(path.join(tmpdir(), "zapp-launch-transport-"));
const prefix = "com.zapp.transport-probe." + randomUUID();
const children = new Set<ReturnType<typeof Bun.spawn>>();
const sockets = new Set<Socket>();
const socketPaths = new Set<string>();
const lockPaths = new Set<string>();
const nativeRoot = path.join(repo, "native/z");
let binary = "";
let leaseRoot = "";
let serial = 0;
const payload = JSON.stringify({ version: 1, launch: { arguments: ["", "draft with spaces", "資料"], workingDirectory: null } });

async function command(args: string[], timeoutMs = 15000) {
  const result = await runBoundedCommand(args, { cwd: root, timeoutMs });
  assert.equal(result.timedOut, false, `Timed out: ${args.join(" ")}`);
  return result;
}
function identity() {
  const id = `${prefix}.${serial++}`;
  const key = createHash("sha256").update(id).digest("hex");
  const socket = `/private/tmp/zapp-launch-${process.geteuid!()}/${key}`;
  socketPaths.add(socket);
  lockPaths.add(path.join(leaseRoot, `${key}.lock`));
  return { id, socket };
}
function frame(text: string | Buffer) {
  const data = Buffer.isBuffer(text) ? text : Buffer.from(text);
  const header = Buffer.alloc(4);
  header.writeUInt32BE(data.length);
  return Buffer.concat([header, data]);
}
function start(id: string, mode = "once") {
  const child = Bun.spawn([binary, id, mode], { cwd: root, detached: true, stdout: "pipe", stderr: "pipe" });
  children.add(child);
  const watchdog = setTimeout(() => signalProcessTree(child, "SIGKILL"), 30000);
  const stderr = new Response(child.stderr).text();
  let output = "";
  let resolveReady!: (value: string) => void;
  let rejectReady!: (error: Error) => void;
  const ready = new Promise<string>((resolve, reject) => { resolveReady = resolve; rejectReady = reject; });
  const stdout = (async () => {
    const reader = child.stdout.getReader();
    const decoder = new TextDecoder();
    try {
      while (true) {
        const next = await reader.read();
        if (next.done) break;
        output += decoder.decode(next.value, { stream: true });
        if (output.includes("\n")) resolveReady(output.split("\n")[0]!);
      }
      if (!output.includes("\n")) rejectReady(new Error(`No readiness: ${await stderr}`));
      return output;
    } finally { reader.releaseLock(); }
  })();
  const exited = child.exited.finally(() => { clearTimeout(watchdog); children.delete(child); });
  return { child, ready, exited, stdout, stderr };
}
async function finish(server: ReturnType<typeof start>, expected: string) {
  assert.equal(await server.exited, 0, await server.stderr);
  assert.equal(await server.stdout, `ready\n${expected}released\n`);
}
async function send(id: string, text = payload, status = 0, result = "accepted") {
  const reply = await command([binary, id, "send", text]);
  assert.equal(reply.status, status, reply.stderr || reply.stdout);
  assert.equal(reply.stdout, result + "\n");
}
async function rawExchange(socketPath: string, pieces: Buffer[], pause = 0) {
  return await new Promise<Buffer>((resolve, reject) => {
    const socket = createConnection(socketPath);
    sockets.add(socket);
    const chunks: Buffer[] = [];
    const deadline = setTimeout(() => socket.destroy(new Error("raw client deadline")), 4000);
    socket.on("data", (chunk) => chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)));
    socket.on("error", (error) => {
      // Reset is a valid bounded rejection for truncated or oversized input.
      if ((error as NodeJS.ErrnoException).code !== "ECONNRESET") reject(error);
    });
    socket.on("close", () => { clearTimeout(deadline); sockets.delete(socket); resolve(Buffer.concat(chunks)); });
    socket.on("connect", async () => {
      for (const piece of pieces) {
        if (socket.destroyed) break;
        socket.write(piece);
        if (pause) await Bun.sleep(pause);
      }
      // Frames, not EOF, delimit requests. Keep the read side alive for the
      // reply; truncated bodies are rejected by the server's absolute deadline.
    });
  });
}
async function fakePrimary(socketPath: string, action: (socket: Socket) => void, run: () => Promise<void>) {
  const active = new Set<Socket>();
  const server = createServer((socket) => { sockets.add(socket); active.add(socket); socket.on("close", () => { sockets.delete(socket); active.delete(socket); }); action(socket); });
  await new Promise<void>((resolve, reject) => { server.once("error", reject); server.listen(socketPath, resolve); });
  await chmod(socketPath, 0o600);
  try { await run(); }
  finally {
    for (const socket of active) socket.destroy();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}

try {
  for (const directory of ["framework/platform/macos", "tests"]) await mkdir(path.join(root, directory), { recursive: true });
  for (const file of [
    "framework/platform/macos/instance-lease.zs", "framework/platform/macos/launch-socket.zs",
    "framework/platform/macos/instance-transport.zs", "framework/activation-inbox.zs",
    "framework/application-launch.zs", "tests/application-instance-transport-smoke.zs",
  ]) await copyFile(path.join(nativeRoot, file), path.join(root, file));
  await writeFile(path.join(root, "z.json"), JSON.stringify({
    package: { name: "zapp-launch-transport-regression", version: "0.1.0" },
    target: { name: "launch-probe", entry: "tests/application-instance-transport-smoke.zs", platform: "macos", minimumVersion: "14.0" },
  }));
  const temp = await command(["getconf", "DARWIN_USER_TEMP_DIR"]);
  assert.equal(temp.status, 0);
  leaseRoot = path.join(temp.stdout.trim(), "zapp-instance-v1");
  binary = path.join(root, "build/launch-probe");
  for (const [name, driver] of [
    ["Stage 0", [process.execPath, path.join(compiler, "compiler/src/cli.ts")]],
    ["native", [path.join(compiler, ".z-cache/bootstrap/z")]],
  ] as const) {
    const build = await command([...driver, "build", root], 180000);
    assert.equal(build.status, 0, build.stderr || build.stdout);
    if (process.env.ZAPP_LAUNCH_UBSAN === "1") {
      const sanitized = await command([
        "clang", "-x", "objective-c", "-std=c11", "-fobjc-arc", "-O1", "-g", "-pthread",
        "-Wall", "-Wextra", "-Werror", "-mmacosx-version-min=14.0",
        "-fsanitize=undefined", "-fno-sanitize-recover=all", "-framework", "Foundation",
        path.join(root, ".z-cache/build/launch-probe.m"), "-o", binary,
      ], 60000);
      assert.equal(sanitized.status, 0, sanitized.stderr);
    }
    const first = identity();
    const server = start(first.id);
    assert.equal(await server.ready, "ready");
    const duplicate = await command([binary, first.id, "once"]);
    assert.equal(duplicate.status, 2, duplicate.stderr);
    await send(first.id);
    await finish(server, "accepted\nqueued 1\n");
    await assert.rejects(lstat(first.socket), { code: "ENOENT" });
    await send(first.id, payload, 6, "unavailable");

    const bounded = identity();
    const batch = start(bounded.id, "batch");
    assert.equal(await batch.ready, "ready");
    // Sequential delivery verifies the exact shared capacity, independent of
    // kernel backlog scheduling. Concurrent clients follow separately.
    for (let index = 0; index < 66; index++) await send(bounded.id, payload, index < 64 ? 0 : 5, index < 64 ? "accepted" : "rejected");
    await finish(batch, "accepted\n".repeat(64) + "rejected\n".repeat(2) + "queued 64\n");

    const concurrent = identity(); const concurrentServer = start(concurrent.id, "batch");
    assert.equal(await concurrentServer.ready, "ready");
    let admitted = 0;
    let refused = 0;
    for (let wave = 0; wave < 11; wave++) {
      const replies = await Promise.all(Array.from({ length: 6 }, () => command([binary, concurrent.id, "send", payload])));
      for (const reply of replies) {
        if (reply.status === 0) { admitted++; assert.equal(reply.stdout, "accepted\n"); }
        else { refused++; assert.equal(reply.status, 5, reply.stderr || reply.stdout); }
      }
    }
    assert.equal(admitted, 64);
    assert.equal(refused, 2);
    await finish(concurrentServer, "accepted\n".repeat(64) + "rejected\n".repeat(2) + "queued 64\n");

    for (const [text, mode] of [["malformed", "once"], [payload, "closed"]]) {
      const target = identity(); const receiver = start(target.id, mode);
      assert.equal(await receiver.ready, "ready");
      await send(target.id, text, 5, "rejected");
      await finish(receiver, "rejected\nqueued 0\n");
    }
    const fragmented = identity(); const fragmentedServer = start(fragmented.id);
    assert.equal(await fragmentedServer.ready, "ready");
    const bytes = frame(payload);
    assert.deepEqual(await rawExchange(fragmented.socket, [bytes.subarray(0, 1), bytes.subarray(1, 3), bytes.subarray(3, 9), bytes.subarray(9)], 20), frame("zapp-launch/1 accepted"));
    await finish(fragmentedServer, "accepted\nqueued 1\n");

    const invalidFrames = [Buffer.from([0, 0, 0, 0]), Buffer.from([0, 1, 0, 1]), Buffer.from([0, 0, 0, 8, 123])];
    for (const invalid of invalidFrames) {
      const target = identity(); const receiver = start(target.id);
      assert.equal(await receiver.ready, "ready");
      assert.equal((await rawExchange(target.socket, [invalid])).length, 0);
      await finish(receiver, "failed\nqueued 0\n");
    }
    const utf8 = identity(); const utf8Server = start(utf8.id);
    assert.equal(await utf8Server.ready, "ready");
    const utf8Reply = await rawExchange(utf8.socket, [frame(Buffer.from([0xff]))]);
    await finish(utf8Server, "rejected\nqueued 0\n");
    assert.deepEqual(utf8Reply, frame("zapp-launch/1 rejected"));

    const slow = identity(); const slowServer = start(slow.id);
    assert.equal(await slowServer.ready, "ready");
    const began = performance.now();
    await rawExchange(slow.socket, Array.from(frame(payload), (byte) => Buffer.from([byte])), 300);
    assert.ok(performance.now() - began < 2500, "slow input must not reset the absolute deadline");
    await finish(slowServer, "failed\nqueued 0\n");

    const crashed = identity(); const crashedServer = start(crashed.id);
    assert.equal(await crashedServer.ready, "ready");
    signalProcessTree(crashedServer.child, "SIGKILL");
    assert.notEqual(await crashedServer.exited, 0);
    const recovered = start(crashed.id);
    assert.equal(await recovered.ready, "ready");
    await send(crashed.id);
    await finish(recovered, "accepted\nqueued 1\n");

    // A peer can accept bytes and lose its acknowledgement. The caller must
    // report uncertainty, never retry or promote itself to primary.
    for (const mode of ["disconnect", "bad-ack", "oversize-ack", "bad-utf8-ack", "timeout"]) {
      const fake = identity();
      const started = performance.now();
      await fakePrimary(fake.socket, (socket) => {
        if (mode === "disconnect") socket.once("data", () => socket.destroy());
        if (mode === "bad-ack") socket.once("data", () => socket.end(frame("wrong-version")));
        if (mode === "oversize-ack") socket.once("data", () => socket.end(Buffer.from([0, 0, 0, 65])));
        if (mode === "bad-utf8-ack") socket.once("data", () => socket.end(frame(Buffer.from([0xff]))));
        if (mode === "timeout") socket.on("data", () => {});
      }, () => send(fake.id, payload, 7, "uncertain"));
      if (mode === "timeout") assert.ok(performance.now() - started < 7000, "the whole client exchange has one five-second deadline");
    }
    await send(identity().id, "", 6, "unavailable");
    await send(identity().id, "a".repeat(65537), 6, "unavailable");
    const hostile = identity();
    const untouched = path.join(root, `untouched-${name.replaceAll(" ", "-")}`);
    await writeFile(untouched, "untouched", { mode: 0o600 });
    await symlink(untouched, hostile.socket);
    const denied = await command([binary, hostile.id, "once"]);
    assert.equal(denied.status, 4, denied.stderr);
    await send(hostile.id, payload, 6, "unavailable");
    assert.equal(await readFile(untouched, "utf8"), "untouched");
    console.log(`${name}: admission, concurrent capacity, fragmentation, malformed input, deadlines, acknowledgement uncertainty, scope cleanup, stale recovery, and unsafe paths passed`);
  }
} finally {
  for (const socket of sockets) socket.destroy();
  await Promise.all([...children].map((child) => terminateProcessTree(child)));
  // Only run-unique names, after all probes have stopped. Production never
  // removes lock files; sockets are removed while the endpoint owns its lease.
  for (const file of [...socketPaths, ...lockPaths]) await rm(file, { force: true });
  await rm(root, { recursive: true, force: true });
}
