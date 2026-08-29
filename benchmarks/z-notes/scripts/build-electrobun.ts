import { rm } from "node:fs/promises";
import { resolve } from "node:path";

const application = resolve(import.meta.dir, "../apps/electrobun");
await rm(resolve(application, "build"), { recursive: true, force: true });
const child = Bun.spawn([
  process.execPath,
  "x",
  "electrobun@2.0.1",
  "build",
  "--env=stable",
], {
  cwd: application,
  stdout: "inherit",
  stderr: "inherit",
});

const status = await child.exited;
if (status !== 0) process.exit(status);
