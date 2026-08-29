import { resolve } from "node:path";

const application = resolve(import.meta.dir, "../apps/tauri");
const icon = resolve(import.meta.dir, "../../../assets/zapp.png");

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
await run([process.execPath, "x", "tauri", "icon", icon, "-o", "src-tauri/icons"]);
await run([process.execPath, "run", "package"]);
