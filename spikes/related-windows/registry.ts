import { join, resolve } from "node:path";
import { mkdir } from "node:fs/promises";
import { runBoundedCommand } from "../../cli/src/bounded-process";

// Headless native proof. No WebKit, network server, sanitizer startup probe, or
// UI is needed for the platform-neutral document/request registry.
const root = resolve(import.meta.dir, "../..");
const zRoot = resolve(root, "../z-lang");
const artifacts = join(import.meta.dir, ".artifacts");
const creations = process.argv.includes("--creations");
const name = creations ? "creations" : "registry";
const source = join(root, "native/z/tests", creations ? "related-creations-smoke.zs" : "related-documents-smoke.zs");
const compiler = process.env.Z_NATIVE_COMPILER ?? join(zRoot, ".z-cache/bootstrap/z");
await mkdir(artifacts, { recursive: true });
const results = [];
for (const frontend of ["native", "stage0"]) {
  const driver = frontend === "native" ? [compiler] : [process.execPath, join(zRoot, "compiler/src/cli.ts")];
  const emission = await runBoundedCommand([...driver, "emit", source], { cwd: root, timeoutMs: 120_000 });
  if (emission.status !== 0 || emission.timedOut) throw new Error(JSON.stringify({ frontend, emission }));
  const generated = join(artifacts, `${name}-${frontend}.c`);
  await Bun.write(generated, emission.stdout);
  for (const optimization of ["-O0", "-O2"]) {
    const binary = join(artifacts, `${name}-${frontend}${optimization}`);
    const compile = await runBoundedCommand(["clang", "-std=c11", optimization, "-g", "-pthread",
      "-Wall", "-Wextra", "-Werror", "-fsanitize=undefined", "-fno-sanitize-recover=all",
      ...(process.platform === "darwin" ? ["-framework", "CoreFoundation"] : []),
      generated, "-o", binary], { cwd: root, timeoutMs: 30_000 });
    if (compile.status !== 0 || compile.timedOut) throw new Error(JSON.stringify({ frontend, compile }));
    const outcome = await runBoundedCommand([binary], { cwd: root, timeoutMs: 10_000 });
    const pass = outcome.status === 0 && !outcome.timedOut && outcome.stderr === ""
      && outcome.stdout === (creations
        ? "related creations: one-shot, readiness, rollback, expiry, owner retirement passed\n"
        : "related document registry: identity, readiness, authority, generations, cancellation passed\n");
    results.push({ frontend, optimization, pass, ...outcome });
    console.log(`${pass ? "PASS" : "FAIL"} ${name} ${frontend} ${optimization}`);
    if (!pass) console.log(outcome);
  }
}
await Bun.write(join(artifacts, `${name}-results.json`), JSON.stringify(results, null, 2) + "\n");
if (results.some(result => !result.pass)) process.exitCode = 1;
