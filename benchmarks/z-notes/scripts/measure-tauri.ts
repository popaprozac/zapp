import { resolve } from "node:path";

const repository = resolve(import.meta.dir, "../../..");
const bundle = resolve(
  import.meta.dir,
  "../apps/tauri/src-tauri/target/release/bundle/macos/Z Notes Benchmark Tauri.app",
);
const runs = process.argv[2] ?? "15";
const child = Bun.spawn([
  resolve(repository, "benchmarks/bench.sh"),
  bundle,
  "tauri-z-notes",
  runs,
], {
  cwd: repository,
  stdout: "inherit",
  stderr: "inherit",
});

const status = await child.exited;
if (status !== 0) process.exit(status);
