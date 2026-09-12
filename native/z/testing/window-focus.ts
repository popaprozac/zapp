/** Bounded window registry/focus checks; --native briefly opens an AppKit window. */
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";
import { runBoundedCommand } from "../../../cli/src/bounded-process";

const root = resolve(import.meta.dir, "../../..");
const zRoot = resolve(process.argv.slice(2).find((arg) => !arg.startsWith("--")) ?? resolve(root, "../z-lang"));
const native = process.argv.includes("--native");
const directory = await mkdtemp(join(tmpdir(), "zapp-window-focus-"));
async function run(command: string[], timeoutMs: number): Promise<string> {
  const result = await runBoundedCommand(command, { cwd: root, timeoutMs });
  if (result.timedOut || result.status !== 0) throw new Error(
    `${command[0]} failed (${result.status}, timeout=${result.timedOut})\n${result.stderr}\n${result.stdout}`);
  return result.stdout;
}
try {
  if (native && process.platform !== "darwin") throw new Error("native focus probe requires macOS");
  const fixtures = native ? ["window-focus-native-smoke"]
    : ["window-focus-smoke", "window-controls-smoke", "window-manager-smoke", "window-events-smoke"];
  for (const fixture of fixtures) {
    const input = resolve(root, `native/z/tests/${fixture}.zs`);
    for (const mode of ["stage0", "native"] as const) {
      const command = mode === "native" && native
        ? [resolve(zRoot, ".z-cache/bootstrap/z"), "emit", input]
        : [process.execPath, resolve(zRoot, "compiler/src/cli.ts"), mode === "stage0" ? "emit" : "self-host-emit", input];
      const source = await run(command, 180_000);
      const file = join(directory, `${fixture}-${mode}.${native ? "m" : "c"}`);
      await writeFile(file, source);
      for (const optimization of ["-O0", "-O2"]) {
        const executable = join(directory, `${fixture}-${mode}${optimization}`);
        await run(["clang", "-std=c11", "-Wall", "-Wextra", "-Werror", optimization,
          ...(native ? ["-fobjc-arc", "-fblocks", "-framework", "AppKit", "-mmacosx-version-min=14.0"] : []),
          "-fsanitize=undefined", "-fno-sanitize-recover=all", file, "-o", executable], 30_000);
        const output = await run([executable], 5_000);
        console.log(`${fixture} ${mode} ${optimization}: passed (UBSan) ${output.trim()}`);
      }
    }
  }
} finally { await rm(directory, { recursive: true, force: true }); }
