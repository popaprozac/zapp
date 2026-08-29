import { resolve } from "node:path";

const application = resolve(import.meta.dir, "../apps/electron");

async function run(command: string[]): Promise<void> {
  const child = Bun.spawn(command, {
    cwd: application,
    stdout: "inherit",
    stderr: "inherit",
  });
  const status = await child.exited;
  if (status !== 0) process.exit(status);
}

await run([process.execPath, "install", "--frozen-lockfile"]);
await run([process.execPath, "run", "package"]);
