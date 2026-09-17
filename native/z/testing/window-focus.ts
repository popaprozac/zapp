/** Bounded window registry/focus checks; --native briefly opens an AppKit window. */
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";
import assert from "node:assert/strict";
import { runBoundedCommand } from "../../../cli/src/bounded-process";

const root = resolve(import.meta.dir, "../../..");
const zRoot = resolve(process.argv.slice(2).find((arg) => !arg.startsWith("--")) ?? resolve(root, "../z-lang"));
const native = process.argv.includes("--native");
const presentationOnly = process.argv.includes("--presentation");
const titlebarOnly = process.argv.includes("--titlebar");
const gesturesOnly = process.argv.includes("--gestures");
const sizingOnly = process.argv.includes("--sizing");
const positioningOnly = process.argv.includes("--positioning");
const restorationOnly = process.argv.includes("--restoration");
const directory = await mkdtemp(join(tmpdir(), "zapp-window-focus-"));
async function run(command: string[], timeoutMs: number): Promise<string> {
  const result = await runBoundedCommand(command, { cwd: root, timeoutMs });
  if (result.timedOut || result.status !== 0) throw new Error(
    `${command[0]} failed (${result.status}, timeout=${result.timedOut})\n${result.stderr}\n${result.stdout}`);
  return result.stdout;
}
try {
  if (native && process.platform !== "darwin") throw new Error("native focus probe requires macOS");
  if (gesturesOnly && !native) throw new Error("gesture lifetime probe requires --native");
  const fixtures = restorationOnly ? [native ? "window-state-native-smoke" : "window-state-smoke"]
    : positioningOnly ? [native ? "window-positioning-native-smoke" : "window-positioning-smoke"]
    : sizingOnly ? [native ? "window-sizing-native-smoke" : "window-sizing-smoke"]
    : gesturesOnly ? ["window-gesture-lifetime-native-smoke"]
    : titlebarOnly ? [native ? "window-titlebar-native-smoke" : "window-titlebar-smoke"]
    : native ? ["window-focus-native-smoke", "window-presentation-native-smoke"]
    : ["window-focus-smoke", "window-controls-smoke", "window-presentation-smoke", "window-manager-smoke", "window-events-smoke", "window-adoption-smoke", "window-family-smoke"];
  for (const fixture of fixtures) {
    if (presentationOnly && !fixture.includes("presentation")) continue;
    const input = resolve(root, `native/z/tests/${fixture}.zs`);
    for (const mode of ["stage0", "native"] as const) {
      const command = mode === "native" && native
        ? [resolve(zRoot, ".z-cache/bootstrap/z"), "emit", input]
        : [process.execPath, resolve(zRoot, "compiler/src/cli.ts"), mode === "stage0" ? "emit" : "self-host-emit", input];
      const source = await run(command, 180_000);
      if (gesturesOnly) {
        const eventBody = source.match(/-\s*\(void\)sendEvent:[^{;\n]+\{([\s\S]*?)(?=\n-\s*\()/)?.[1];
        assert.ok(eventBody, `${mode}: missing native sendEvent override`);
        assert.equal(eventBody.match(/_z_native_subclass_handoff_begin\(/g)?.length, 2,
          `${mode}: both live/expired observer arms must release access during superclass event routing`);
      }
      const file = join(directory, `${fixture}-${mode}.${native ? "m" : "c"}`);
      await writeFile(file, source);
      for (const optimization of ["-O0", "-O2"]) {
        const executable = join(directory, `${fixture}-${mode}${optimization}`);
        await run(["clang", "-std=c11", "-Wall", "-Wextra", "-Werror", optimization,
          ...(native ? ["-fobjc-arc", "-fblocks", "-framework", "AppKit", "-framework", "WebKit", "-framework", "QuartzCore", "-mmacosx-version-min=14.0"] : []),
          "-fsanitize=undefined", "-fno-sanitize-recover=all", file, "-o", executable], 30_000);
        const output = await run([executable, ...(restorationOnly ? [join(directory, `${mode}${optimization}-state`)] : [])], native ? 15_000 : 5_000);
        console.log(`${fixture} ${mode} ${optimization}: passed (UBSan) ${output.trim()}`);
      }
    }
  }
} finally {
  if (process.env.ZAPP_TEST_KEEP_ARTIFACTS === "1") console.log(`Test artifacts: ${directory}`);
  else await rm(directory, { recursive: true, force: true });
}
