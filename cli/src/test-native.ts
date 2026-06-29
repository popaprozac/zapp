// Runs native unit tests:
//   1. Zen-C: `test "..." { assert }` blocks via `zc run` on native/tests/*_test.zc.
//      Zen-C exits with the failure count (0 = all passed).
//   2. Nim: standalone scripts via `nim r` on native/nim/tests/*_test.nim.
//      nim r exits 0 on success, non-zero on assertion failure or compile error.
import { Glob } from "bun";
import path from "node:path";
import { clog } from "./log";

const ROOT = path.resolve(import.meta.dir, "..", ".."); // cli/src -> repo root
const zc = Bun.which("zc") ?? "zc";
const nim = Bun.which("nim") ?? "nim";

// --- Zen-C tests (native/tests/*_test.zc) -----------------------------------
const zcFiles = [...new Glob("native/tests/*_test.zc").scanSync({ cwd: ROOT })].sort();

if (zcFiles.length === 0) {
  clog(0, "no Zen-C native tests found (native/tests/*_test.zc)");
}

let failed = 0;
for (const rel of zcFiles) {
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

// --- Nim tests (native/nim/tests/*_test.nim) --------------------------------
const nimFiles = [
  ...new Glob("native/nim/tests/*_test.nim").scanSync({ cwd: ROOT }),
].sort();

if (nimFiles.length === 0) {
  clog(0, "no Nim native tests found (native/nim/tests/*_test.nim)");
}

for (const rel of nimFiles) {
  const proc = Bun.spawnSync([nim, "r", rel], { cwd: ROOT, stdout: "pipe", stderr: "pipe" });
  const out =
    new TextDecoder().decode(proc.stdout) + new TextDecoder().decode(proc.stderr);
  const ok = proc.exitCode === 0;
  console.log(`${ok ? "PASS" : "FAIL"}  ${rel}`);
  if (!ok) {
    failed++;
    for (const line of out.split("\n")) {
      if (/error|FAIL|failed|assertion/i.test(line)) console.log("    " + line.trimEnd());
    }
  }
}

const total = zcFiles.length + nimFiles.length;
console.log(
  `\n${failed === 0 ? `all ${total} native tests passed` : `${failed} native test file(s) failed`}`,
);
process.exit(failed === 0 ? 0 : 1);
