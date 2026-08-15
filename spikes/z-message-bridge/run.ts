import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { resolve } from "node:path";

const spike = import.meta.dir;
const repository = resolve(spike, "../..");
const siblingCompiler = resolve(repository, "../z-lang/.z-cache/bootstrap/z");
const compiler = process.env.ZAPP_Z_COMPILER
  ?? (existsSync(siblingCompiler) ? siblingCompiler : "z");
const userNim = resolve(homedir(), ".nimble/bin/nim");
const nim = process.env.ZAPP_NIM
  ?? (existsSync(userNim) ? userNim : "nim");
const build = resolve(spike, "build");
const archive = resolve(build, "libzapp_message_bridge.a");
const host = resolve(build, "zapp-message-bridge-host");
const nimcache = resolve(build, "nimcache");

async function run(command: string[], cwd = repository): Promise<void> {
  const child = Bun.spawn(command, {
    cwd,
    stdout: "inherit",
    stderr: "inherit",
  });
  const status = await child.exited;
  if (status !== 0) {
    throw new Error(`${command[0]} exited with status ${status}`);
  }
}

await run([compiler, "build", spike]);
await run([
  nim,
  "c",
  `--cc:${process.platform === "win32" ? "gcc" : "clang"}`,
  "--mm:orc",
  "-d:release",
  "--opt:size",
  `--nimcache:${nimcache}`,
  `--passL:${archive}`,
  `-o:${host}`,
  resolve(spike, "host.nim"),
]);
await run([host]);
