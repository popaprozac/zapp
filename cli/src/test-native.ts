// Runs Zen-C native unit tests (`test "..." { assert }` blocks) by invoking
// `zc run` on each native/tests/*_test.zc. Zen-C exits with the failure
// count (0 = all passed); we aggregate and exit non-zero if any file fails.
import { Glob } from "bun";
import path from "node:path";
import { clog } from "./log";

const ROOT = path.resolve(import.meta.dir, "..", ".."); // cli/src -> repo root
const zc = Bun.which("zc") ?? "zc";

const files = [...new Glob("native/tests/*_test.zc").scanSync({ cwd: ROOT })].sort();

if (files.length === 0) {
  clog(0, "no native tests found (native/tests/*_test.zc)");
  process.exit(0);
}

let failed = 0;
for (const rel of files) {
  const proc = Bun.spawnSync([zc, "run", rel], { cwd: ROOT, stdout: "pipe", stderr: "pipe" });
  const out =
    new TextDecoder().decode(proc.stdout) + new TextDecoder().decode(proc.stderr);
  const ok = proc.exitCode === 0;
  console.log(`${ok ? "PASS" : "FAIL"}  ${rel}`);
  if (!ok) {
    failed++;
    for (const line of out.split("\n")) {
      if (/TEST:|FAIL|error|failed/i.test(line)) console.log("    " + line.trimEnd());
    }
  }
}

console.log(`\n${failed === 0 ? "all native tests passed" : `${failed} native test file(s) failed`}`);
process.exit(failed === 0 ? 0 : 1);
