// Bounded, real multi-process primary-election regression, outside unit glob.
// Run: bun run cli/src/test-instance-lease-macos.ts
// Z_SOURCE_ROOT may select a sibling compiler checkout; both compiler paths run.
import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { chmod, copyFile, link, mkdir, mkdtemp, readFile, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { runBoundedCommand, signalProcessTree, terminateProcessTree } from "./bounded-process";

if (process.platform !== "darwin") throw new Error("Instance lease regression requires macOS");
const repo = path.resolve(import.meta.dir, "../..");
const compiler = process.env.Z_SOURCE_ROOT ?? path.resolve(repo, "../z-lang");
const root = await mkdtemp(path.join(tmpdir(), "zapp-instance-lease-"));
const identifier = "com.zapp.instance-probe." + randomUUID();
const children = new Set<ReturnType<typeof Bun.spawn>>();
const lockPaths = new Set<string>();
let binary = "";
let leaseRoot = "";

async function command(args: string[], timeoutMs = 15000) {
  const result = await runBoundedCommand(args, { cwd: root, timeoutMs });
  assert.equal(result.timedOut, false, `Timed out: ${args.join(" ")}`);
  return result;
}
async function checked(args: string[], timeoutMs = 15000) {
  const result = await command(args, timeoutMs);
  assert.equal(result.status, 0, result.stderr || result.stdout || args.join(" "));
  return result;
}
function lockPath(id: string) {
  const key = createHash("sha256").update(id, "utf8").digest("hex");
  const value = path.join(leaseRoot, key + ".lock");
  lockPaths.add(value);
  return value;
}
async function probe(id: string, expected: number, mode = "once") {
  const result = await command([binary, id, mode]);
  assert.equal(result.status, expected, result.stderr || result.stdout);
  if (expected === 0) assert.equal(result.stdout, mode === "release" ? "primary\nprimary\n" : "primary\n");
  if (expected === 2) assert.equal(result.stdout, "secondary\n");
  return result;
}

// Observe readiness, not a fixed delay; every long-lived child has a watchdog.
function start(id: string) {
  const child = Bun.spawn([binary, id, "hold"], {
    cwd: root, detached: true, stdout: "pipe", stderr: "pipe",
  });
  children.add(child);
  const watchdog = setTimeout(() => signalProcessTree(child, "SIGKILL"), 15000);
  const stderr = new Response(child.stderr).text();
  const ready = (async () => {
    const reader = child.stdout.getReader();
    try {
      let text = "";
      while (!text.includes("\n")) {
        const next = await reader.read();
        if (next.done) throw new Error(`Probe exited before readiness: ${await stderr}`);
        text += new TextDecoder().decode(next.value);
      }
      return text.trim();
    } finally {
      reader.releaseLock();
    }
  })();
  const exited = child.exited.finally(() => {
    clearTimeout(watchdog);
    children.delete(child);
  });
  return { child, ready, exited, stderr };
}

try {
  // Copy the exact source into an isolated package so building does not touch
  // the application's generated core, interactive bundle, or source caches.
  await mkdir(path.join(root, "framework/platform/macos"), { recursive: true });
  await mkdir(path.join(root, "tests"));
  for (const relative of [
    "framework/platform/macos/instance-lease.zs",
    "tests/application-instance-lease-smoke.zs",
  ]) await copyFile(path.join(repo, "native/z", relative), path.join(root, relative));
  await writeFile(path.join(root, "z.json"), JSON.stringify({
    package: { name: "zapp-instance-lease-regression", version: "0.1.0" },
    target: {
      name: "instance-lease-probe", entry: "tests/application-instance-lease-smoke.zs",
      platform: "macos", minimumVersion: "14.0",
    },
  }));
  const userTemp = (await checked(["getconf", "DARWIN_USER_TEMP_DIR"])).stdout.trim();
  leaseRoot = path.join(userTemp, "zapp-instance-v1");
  binary = path.join(root, "build/instance-lease-probe");

  for (const [name, driver] of [
    ["Stage 0", [process.execPath, path.join(compiler, "compiler/src/cli.ts")]],
    ["native", [path.join(compiler, ".z-cache/bootstrap/z")]],
  ] as const) {
    await checked([...driver, "build", root], 180000);
    const id = identifier + (name === "native" ? ".native" : ".stage0");
    const primaryPath = lockPath(id);
    // Z scope cleanup releases the lease before a second acquisition in the
    // same process; process exit alone cannot satisfy this regression.
    await probe(id, 0, "release");
    const inode = (await stat(primaryPath)).ino;
    const primary = start(id);
    assert.equal(await primary.ready, "primary");
    await probe(id, 2);
    const independent = id + ".independent";
    lockPath(independent);
    await probe(independent, 0);
    // Kernel ownership survives contention and ends on normal exit.
    assert.equal(await primary.exited, 0, await primary.stderr);
    await probe(id, 0);
    assert.equal((await stat(primaryPath)).ino, inode, "lease inode must remain stable");

    const crashed = start(id);
    assert.equal(await crashed.ready, "primary");
    signalProcessTree(crashed.child, "SIGKILL");
    assert.notEqual(await crashed.exited, 0);
    await probe(id, 0);
    assert.equal((await stat(primaryPath)).ino, inode);

    const contenders = Array.from({ length: 6 }, () => start(id));
    const outcomes = await Promise.all(contenders.map((item) => item.ready));
    assert.equal(outcomes.filter((value) => value === "primary").length, 1, outcomes.join(", "));
    assert.equal(outcomes.filter((value) => value === "secondary").length, 5, outcomes.join(", "));
    for (let index = 0; index < contenders.length; index++) {
      if (outcomes[index] === "primary") await terminateProcessTree(contenders[index]!.child);
      else assert.equal(await contenders[index]!.exited, 2);
    }
    await probe(id, 0);

    await probe("", 3);
    // Names remain data, never paths; no new public identifier grammar or
    // filename-length limit is needed for primary arbitration.
    for (const suffix of ["/../escape", " has space", ".資料", "." + "a".repeat(300)]) {
      const unusual = id + suffix;
      lockPath(unusual);
      await probe(unusual, 0);
    }
    // These paths are unique to this run; never change a real app's lock.
    const hostile = id + ".hostile";
    const hostilePath = lockPath(hostile);
    const target = path.join(root, "untouched-target");
    await writeFile(target, "untouched", { mode: 0o600 });
    await symlink(target, hostilePath);
    await probe(hostile, 3);
    assert.equal(await readFile(target, "utf8"), "untouched");
    await rm(hostilePath);
    await mkdir(hostilePath, { mode: 0o700 });
    await probe(hostile, 3);
    await rm(hostilePath, { recursive: true });
    await writeFile(hostilePath, "", { mode: 0o644 });
    await chmod(hostilePath, 0o644); // Do not let a restrictive test umask mask the case.
    await probe(hostile, 3);
    await rm(hostilePath);
    await link(primaryPath, hostilePath);
    await probe(hostile, 3);
    await rm(hostilePath);
    console.log(`${name}: scope cleanup, contention, independent identities, crash recovery, simultaneous launch, and unsafe-path rejection passed`);
  }
} finally {
  await Promise.all([...children].map((child) => terminateProcessTree(child)));
  // Production never unlinks leases. Only remove this test's unique names,
  // after every process that could hold or open them has finished.
  for (const file of lockPaths) await rm(file, { recursive: true, force: true });
  await rm(root, { recursive: true, force: true });
}
