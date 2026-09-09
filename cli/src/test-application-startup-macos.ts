// Complete Application.run gate, not a transport-only surrogate. Builds and
// launches a private app identity; deadlines own every process and resource.
import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { copyFile, lstat, mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import path from "node:path";
import { runBoundedCommand, signalProcessTree, terminateProcessTree } from "./bounded-process";
import { compileNative } from "./native";
import { createDevBundle } from "./bundle";
import type { ResolvedConfig } from "./config";

const repo = path.resolve(import.meta.dir, "../..");
if (process.platform !== "darwin") throw new Error("Application startup regression requires macOS");

if (process.argv[2] === "--build") {
  const root = process.argv[3]!;
  const identifier = process.argv[4]!;
  const config: ResolvedConfig = {
    name: "Zapp Startup Probe", identifier, version: "0.1.0", assetDir: "dist",
    singleInstance: true, permissions: ["window:create", "application:quit"],
    capabilityProfiles: { default: { permissions: ["window:create", "application:quit"] } },
    macos: { minimumSystemVersion: "14.0" },
  };
  process.env.ZAPP_NATIVE_LANG = "z";
  process.env.ZAPP_Z_HOST = "desktop";
  delete process.env.ZAPP_Z_DESKTOP_SMOKE_SUPPORT;
  const output = path.join(root, "build/startup-probe");
  await compileNative({ root, output, nativeDir: path.join(repo, "native"),
    buildFile: "", buildConfigFile: "", target: "macos", optimize: true, config });
  await createDevBundle(root, output, config, { smoke: true });
  process.exit(0);
}

await mkdir(path.join(repo, ".zapp"), { recursive: true });
const root = await mkdtemp(path.join(repo, ".zapp/application-startup-"));
const identifier = `com.zapp.application-startup.${randomUUID()}`;
const key = createHash("sha256").update(identifier).digest("hex");
const socket = `/private/tmp/zapp-launch-${process.geteuid!()}/${key}`;
const children = new Set<ReturnType<typeof Bun.spawn>>();
const binary = path.join(root, ".zapp/smoke/bin/Zapp Startup Probe.app/Contents/MacOS/startup-probe");
let lease = "";

function launch(mode: string) {
  const args = mode === "secondary" ? [mode, "", "draft with spaces", "資料"] : [mode];
  const child = Bun.spawn([binary, ...args], { cwd: root, detached: true, stdout: "pipe", stderr: "pipe" });
  children.add(child);
  const timer = setTimeout(() => signalProcessTree(child, "SIGKILL"), 15_000);
  const stderr = new Response(child.stderr).text();
  let ready!: () => void;
  const started = new Promise<void>((resolve) => { ready = resolve; });
  const stdout = (async () => {
    const reader = child.stdout.getReader();
    const decoder = new TextDecoder();
    let output = "";
    try {
      while (true) {
        const next = await reader.read();
        if (next.done) break;
        output += decoder.decode(next.value, { stream: true });
        if (output.includes("service started\n")) ready();
      }
      return output + decoder.decode();
    } finally { reader.releaseLock(); }
  })();
  const exited = child.exited.finally(() => { clearTimeout(timer); children.delete(child); });
  const waitReady = Promise.race([started, exited.then(async () => {
    throw new Error(`Primary exited before service startup: ${await stdout}\n${await stderr}`);
  })]);
  // Failure probes do not wait for service startup, but still observe rejection.
  void waitReady.catch(() => {});
  return { stdout, stderr, exited, waitReady };
}

async function successful(child: ReturnType<typeof launch>) {
  const status = await child.exited;
  const output = await child.stdout;
  assert.equal(status, 0, `${output}\n${await child.stderr}`);
  assert.ok(output.includes("stopped true\n"), output);
  return output;
}

try {
  await mkdir(path.join(root, "zapp"), { recursive: true });
  await mkdir(path.join(root, "dist"), { recursive: true });
  await copyFile(path.join(repo, "native/z/tests/application-run-startup-smoke.zs"), path.join(root, "zapp/main.zs"));
  await writeFile(path.join(root, "dist/index.html"), "<!doctype html><title>Startup probe</title><p>Application startup regression</p>");
  const build = await runBoundedCommand([process.execPath, import.meta.path, "--build", root, identifier], {
    cwd: repo, timeoutMs: 240_000,
  });
  process.stdout.write(build.stdout);
  assert.equal(build.timedOut, false, "Application startup build timed out");
  assert.equal(build.status, 0, build.stderr || build.stdout);
  assert.equal((await lstat(binary)).isFile(), true, "Signed startup probe is missing");
  const temp = await runBoundedCommand(["getconf", "DARWIN_USER_TEMP_DIR"], { cwd: root, timeoutMs: 5_000 });
  assert.equal(temp.status, 0, temp.stderr);
  lease = path.join(temp.stdout.trim(), "zapp-instance-v1", `${key}.lock`);

  // A failed startup must release the same identity before the next launch.
  await mkdir(path.dirname(socket), { recursive: true, mode: 0o700 });
  await symlink(path.join(root, "missing"), socket);
  const endpoint = await successful(launch("endpoint-failure"));
  assert.equal(endpoint, "host false\nstopped true\n");
  assert.equal((await lstat(socket)).isSymbolicLink(), true);
  await rm(socket);
  console.log("Application.run: endpoint failure rolled back before AppKit");

  const lifecycle = await successful(launch("lifecycle-failure"));
  assert.equal(lifecycle, "service started\nhost true\nstopped true\n");
  await assert.rejects(lstat(socket), { code: "ENOENT" });
  console.log("Application.run: service startup failure joined listener and released endpoint");

  const primary = launch("primary");
  await primary.waitReady;
  const secondary = await successful(launch("secondary"));
  assert.equal(secondary, "host false\nstopped true\n");
  const output = await successful(primary);
  assert.equal(output.split("service started\n").length - 1, 1);
  assert.equal(output.split("service stopped\n").length - 1, 1);
  const launches = output.split("\n").filter((line) => line.startsWith("launch "));
  assert.equal(launches.length, 1, output);
  assert.deepEqual(JSON.parse(launches[0]!.slice(7)), {
    arguments: ["secondary", "", "draft with spaces", "資料"], workingDirectory: root,
  });
  assert.ok(output.includes("host true\n"), output);
  await assert.rejects(lstat(socket), { code: "ENOENT" });
  console.log("Application.run: primary/secondary delivered once; secondary created no AppKit host or services");
} finally {
  await Promise.all([...children].map((child) => terminateProcessTree(child)));
  await rm(socket, { force: true });
  if (lease) await rm(lease, { force: true });
  await rm(root, { recursive: true, force: true });
}
