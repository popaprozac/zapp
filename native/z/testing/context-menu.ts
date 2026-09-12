/** Bounded, non-GUI lifecycle verification through both Z compilers. */
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";
import { runBoundedCommand } from "../../../cli/src/bounded-process";

const root = resolve(import.meta.dir, "../../..");
const zRoot = resolve(process.argv[2] ?? resolve(root, "../z-lang"));
const directory = await mkdtemp(join(tmpdir(), "zapp-context-menu-"));

async function run(command: string[], timeoutMs: number): Promise<string> {
  const result = await runBoundedCommand(command, { cwd: root, timeoutMs });
  if (result.timedOut || result.status !== 0) {
    throw new Error(`${command[0]} failed (${result.status}, timeout=${result.timedOut})\n${result.stderr}\n${result.stdout}`);
  }
  return result.stdout;
}

try {
  // self-host-emit rebuilds the native emitter when its Z sources change.
  // Captured C is generated output, never checked-in source.
  const cli = resolve(zRoot, "compiler/src/cli.ts");
  for (const fixture of ["context-menu-smoke", "context-menu-bridge-smoke"]) {
    const input = resolve(root, `native/z/tests/${fixture}.zs`);
    for (const mode of ["emit", "self-host-emit"] as const) {
      const source = await run([process.execPath, cli, mode, input], 180_000);
      const file = join(directory, `${mode}.c`);
      await writeFile(file, source);
      for (const optimization of ["-O0", "-O2"]) {
        const executable = join(directory, `${mode}${optimization}`);
        await run([
          "clang", "-std=c11", "-Wall", "-Wextra", "-Werror",
          optimization, "-fsanitize=undefined", "-fno-sanitize-recover=all",
          file, "-o", executable,
        ], 30_000);
        await run([executable], 5_000);
        console.log(`${fixture} ${mode} ${optimization}: passed (UBSan)`);
      }
    }
  }
} finally {
  await rm(directory, { recursive: true, force: true });
}
