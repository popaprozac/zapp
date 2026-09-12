/** Bounded tray registry verification; --native also exercises AppKit. */
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";
import { runBoundedCommand } from "../../../cli/src/bounded-process";

const root = resolve(import.meta.dir, "../../..");
const zRoot = resolve(process.argv.slice(2).find((arg) => !arg.startsWith("--")) ?? resolve(root, "../z-lang"));
const directory = await mkdtemp(join(tmpdir(), "zapp-tray-"));
async function run(command: string[], timeoutMs: number): Promise<string> {
  const result = await runBoundedCommand(command, { cwd: root, timeoutMs });
  if (result.timedOut || result.status !== 0) throw new Error(
    `${command[0]} failed (${result.status}, timeout=${result.timedOut})\n${result.stderr}\n${result.stdout}`);
  return result.stdout;
}
try {
  const native = process.argv.includes("--native");
  if (native && process.platform !== "darwin") throw new Error("native tray probe requires macOS");
  const input = resolve(root, `native/z/tests/${native ? "tray-native-smoke" : "tray-smoke"}.zs`);
  for (const mode of ["emit", "self-host-emit"] as const) {
    // The standalone driver loads Clang declaration evidence. The parser
    // library's self-host-emit probe deliberately has no foreign adapter.
    const command = native && mode === "self-host-emit"
      ? [resolve(zRoot, ".z-cache/bootstrap/z"), "emit", input]
      : [process.execPath, resolve(zRoot, "compiler/src/cli.ts"), mode, input];
    const source = await run(command, 180_000);
    const file = join(directory, `${mode}.${native ? "m" : "c"}`);
    await writeFile(file, source);
    for (const optimization of ["-O0", "-O2"]) {
      const executable = join(directory, `${mode}${optimization}`);
      await run(["clang", "-std=c11", "-Wall", "-Wextra", "-Werror", optimization,
        ...(native ? ["-fobjc-arc", "-fblocks", "-framework", "AppKit", "-mmacosx-version-min=14.0"] : []),
        "-fsanitize=undefined", "-fno-sanitize-recover=all", file, "-o", executable], 30_000);
      await run([executable], 5_000);
      console.log(`tray ${native ? "AppKit" : "registry"} ${mode} ${optimization}: passed (UBSan)`);
    }
  }
} finally { await rm(directory, { recursive: true, force: true }); }
