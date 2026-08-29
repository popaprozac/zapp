import { resolve } from "node:path";

const repository = resolve(import.meta.dir, "../../..");
const bundle = resolve(
  import.meta.dir,
  "../apps/wails/release/Z Notes Benchmark Wails.app",
);
const runs = process.argv[2] ?? "15";
const child = Bun.spawn([
  resolve(repository, "benchmarks/bench.sh"),
  bundle,
  "wails-z-notes",
  runs,
], {
  cwd: repository,
  stdout: "inherit",
  stderr: "inherit",
});

const status = await child.exited;
if (status !== 0) process.exit(status);
