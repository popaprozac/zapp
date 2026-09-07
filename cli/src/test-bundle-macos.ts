// Real signing/LaunchServices regression; intentionally outside unit-test glob.
// Run: bun run cli/src/test-bundle-macos.ts
import { mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import assert from "node:assert/strict";
import { createDevBundle } from "./bundle";
import { runBoundedCommand } from "./bounded-process";

if (process.platform !== "darwin") {
  throw new Error("The LaunchServices bundle regression requires macOS");
}
const root = await mkdtemp(path.join(tmpdir(), "zapp-bundle-native-"));
const registration = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";
let app: string | undefined;
let launchCount = 0;
async function checked(command: string[]) {
  const result = await runBoundedCommand(command, { cwd: root, timeoutMs: 15000 });
  assert.equal(result.timedOut, false, command.join(" "));
  assert.equal(result.status, 0, result.stderr || command.join(" "));
}
async function launch(expected: string) {
  // open appends to its output files, so each launch needs fresh capture paths.
  const prefix = String(++launchCount) + "-" + expected;
  const output = path.join(root, prefix + ".stdout");
  const errors = path.join(root, prefix + ".stderr");
  await checked(["open", "-W", "-a", app!, "--stdout", output, "--stderr", errors]);
  assert.equal((await readFile(output, "utf8")).trim(), expected);
}
try {
  const source = path.join(root, "probe.c");
  const first = path.join(root, "old-host");
  const second = path.join(root, "new-host");
  await writeFile(source, '#include <stdio.h>\nint main(void) { puts("old-host"); return 0; }\n');
  await checked(["xcrun", "clang", source, "-o", first]);
  await writeFile(source, '#include <stdio.h>\nint main(void) { puts("new-host"); return 0; }\n');
  await checked(["xcrun", "clang", source, "-o", second]);
  const config = { name: "Zapp Bundle Probe", identifier: "com.zapp.bundle-probe." + process.pid, version: "0.1.0", assetDir: "dist" };
  app = await createDevBundle(root, first, config);
  await launch("old-host");
  app = await createDevBundle(root, second, { ...config, identifier: config.identifier + ".changed" });
  assert.deepEqual(await readdir(path.join(app, "Contents", "MacOS")), ["new-host"]);
  await launch("new-host");

  const before = await readFile(path.join(app, "Contents", "MacOS", "new-host"));
  const smoke = await createDevBundle(root, first, { ...config, deepLinkSchemes: ["zapp-bundle-probe"] }, { smoke: true });
  assert.notEqual(smoke, app);
  assert.equal((await readFile(path.join(smoke, "Contents", "Info.plist"), "utf8")).includes("CFBundleURLTypes"), false);
  assert.deepEqual(await readFile(path.join(app, "Contents", "MacOS", "new-host")), before);
  await launch("new-host");
  console.log("Native bundle replacement, changed executable/identity, and smoke isolation passed");
} finally {
  if (app) await runBoundedCommand([registration, "-u", app], { cwd: root, timeoutMs: 15000 });
  await rm(root, { recursive: true, force: true });
}
