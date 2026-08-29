import { resolve } from "node:path";

const repository = resolve(import.meta.dir, "../../..");
const application = resolve(import.meta.dir, "../apps/zapp");
const child = Bun.spawn([
  process.execPath,
  "run",
  "cli/src/zapp-cli.ts",
  "package",
  "-r",
  application,
], {
  cwd: repository,
  env: {
    ...process.env,
    ZAPP_NATIVE_LANG: "z",
    ZAPP_Z_HOST: "desktop",
  },
  stdout: "inherit",
  stderr: "inherit",
});

const status = await child.exited;
if (status !== 0) process.exit(status);
