import { resolve } from "node:path";

const repository = resolve(import.meta.dir, "../../..");
const bundle = resolve(
  import.meta.dir,
  "../apps/zapp/release/Z Notes Benchmark.app",
);
const runs = process.argv[2] ?? "15";
const child = Bun.spawn([
  resolve(repository, "benchmarks/bench.sh"),
  bundle,
  "zapp-z-notes",
  runs,
], {
  cwd: repository,
  stdout: "inherit",
  stderr: "inherit",
});

const status = await child.exited;
if (status !== 0) process.exit(status);
