// Real endpoint + worker + main executor lifecycle, with bounded teardown.
import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { copyFile, lstat, mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { createConnection, type Socket } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { runBoundedCommand, signalProcessTree, terminateProcessTree } from "./bounded-process";

if (process.platform !== "darwin") throw new Error("Launch listener regression requires macOS");
const repo = path.resolve(import.meta.dir, "../..");
const compiler = process.env.Z_SOURCE_ROOT ?? path.resolve(repo, "../z-lang");
const root = await mkdtemp(path.join(tmpdir(), "zapp-launch-listener-"));
const children = new Set<ReturnType<typeof Bun.spawn>>();
const sockets = new Set<Socket>();
const paths = new Set<string>();
const binary = path.join(root, "build/listener-probe");
const payload = Buffer.from(JSON.stringify({ version: 1, launch: {
  arguments: ["", "draft with spaces", "資料"], workingDirectory: null,
} }));
const header = Buffer.alloc(4);
header.writeUInt32BE(payload.length);
async function command(args: string[], timeoutMs = 15_000) {
  const result = await runBoundedCommand(args, { cwd: root, timeoutMs });
  assert.equal(result.timedOut, false, `Timed out: ${args.join(" ")}`);
  assert.equal(result.status, 0, result.stderr || result.stdout);
  return result;
}
function start(id: string, mode: string) {
  const child = Bun.spawn([binary, id, mode], { cwd: root, detached: true, stdout: "pipe", stderr: "pipe" });
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
      if (!output.includes("\n")) rejectReady(new Error(`Listener exited before readiness: ${await stderr}`));
      return output;
    } finally { reader.releaseLock(); }
  })();
  const exited = child.exited.finally(() => { clearTimeout(watchdog); children.delete(child); });
  return { ready, stdout, stderr, exited };
}
async function exchange(socketPath: string, partial: boolean) {
  return await new Promise<Buffer>((resolve, reject) => {
    const socket = createConnection(socketPath);
    sockets.add(socket);
    const chunks: Buffer[] = [];
    const deadline = setTimeout(() => socket.destroy(new Error("listener client deadline")), 3_000);
    socket.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
    socket.on("error", reject);
    socket.on("close", () => {
      clearTimeout(deadline); sockets.delete(socket); resolve(Buffer.concat(chunks));
    });
    socket.on("connect", () => socket.write(partial ? header.subarray(0, 1) : Buffer.concat([header, payload])));
  });
}

try {
  const files = [
    "framework/platform/macos/instance-lease.zs", "framework/platform/macos/launch-socket.zs",
    "framework/platform/macos/instance-transport.zs", "framework/activation-inbox.zs",
    "framework/application-launch.zs", "tests/application-launch-listener-smoke.zs",
  ];
  for (const file of files) {
    const target = path.join(root, file);
    await mkdir(path.dirname(target), { recursive: true });
    await copyFile(path.join(repo, "native/z", file), target);
  }
  await writeFile(path.join(root, "z.json"), JSON.stringify({
    package: { name: "zapp-launch-listener-regression", version: "0.1.0" },
    target: { name: "listener-probe", entry: "tests/application-launch-listener-smoke.zs", platform: "macos", minimumVersion: "14.0" },
  }));
  const userTemp = (await command(["getconf", "DARWIN_USER_TEMP_DIR"])).stdout.trim();
  const frontends = [
    { name: "Stage 0", args: [process.execPath, path.join(compiler, "compiler/src/cli.ts")] },
    { name: "native", args: [path.join(compiler, ".z-cache/bootstrap/z")] },
  ];
  for (const frontend of frontends) {
    await command([...frontend.args, "build", root], 180_000);
    if (process.env.ZAPP_LAUNCH_UBSAN === "1") {
      await command(["clang", "-x", "objective-c", "-std=c11", "-fobjc-arc", "-O1", "-g", "-pthread",
        "-Wall", "-Wextra", "-Werror", "-mmacosx-version-min=14.0",
        "-fsanitize=undefined", "-fno-sanitize-recover=all", "-framework", "Foundation", "-framework", "CoreFoundation",
        path.join(root, ".z-cache/build/listener-probe.m"), "-o", binary], 60_000);
    }
    for (const mode of ["normal", "closed-scope", "idle", "partial", "startup-failure"]) {
      const id = `com.zapp.listener-probe.${randomUUID()}`;
      const key = createHash("sha256").update(id).digest("hex");
      const socket = `/private/tmp/zapp-launch-${process.geteuid!()}/${key}`;
      paths.add(socket);
      paths.add(path.join(userTemp, "zapp-instance-v1", `${key}.lock`));
      if (mode === "startup-failure") {
        await mkdir(path.dirname(socket), { recursive: true, mode: 0o700 });
        await symlink(path.join(root, "missing-target"), socket);
      }
      const server = start(id, mode);
      const ready = mode === "startup-failure" ? "startup 4" : "ready";
      assert.equal(await server.ready, ready);
      const began = performance.now();
      if (mode === "normal") {
        const secondary = start(id, "secondary");
        assert.equal(await secondary.ready, "startup 3");
        assert.equal(await secondary.exited, 0, `${await secondary.stdout}\n${await secondary.stderr}`);
        assert.equal(await secondary.stdout, "startup 3\nlistener joined\nupdates joined\nprimary preserved\ndelivered 0\nhost released\n");
        assert.equal(await secondary.stderr, "");
      }
      if (mode === "normal" || mode === "closed-scope") {
        const response = await exchange(socket, false);
        assert.equal(response.subarray(4).toString(), "zapp-launch/1 accepted");
      } else if (mode === "partial") {
        const response = await exchange(socket, true);
        assert.equal(response.length, 0);
      }
      assert.equal(await server.exited, 0, `${frontend.name}/${mode}\n${await server.stdout}\n${await server.stderr}`);
      assert.equal(await server.stderr, "");
      assert.equal(await server.stdout, `${ready}\nlistener joined\nupdates joined\nlease released\ndelivered ${mode === "normal" ? 1 : 0}\nhost released\n`);
      assert.ok(performance.now() - began < 4_000, `${mode} did not shut down within receive deadline`);
      if (mode === "startup-failure") assert.equal((await lstat(socket)).isSymbolicLink(), true);
      else await assert.rejects(lstat(socket), { code: "ENOENT" });
      console.log(`${frontend.name}: ${mode} passed`);
    }
  }
} finally {
  for (const socket of sockets) socket.destroy();
  await Promise.all([...children].map((child) => terminateProcessTree(child)));
  // Only this run's random identities, after every owning process has exited.
  for (const file of paths) await rm(file, { force: true });
  await rm(root, { recursive: true, force: true });
}
