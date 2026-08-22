import { resolve } from "node:path";
import { compileNative } from "../../cli/src/native";

const spike = import.meta.dir;
const repository = resolve(spike, "../..");
const build = resolve(spike, "build");
const host = resolve(build, "zapp-message-bridge-host");

async function run(command: string[]): Promise<void> {
  const child = Bun.spawn(command, {
    cwd: repository,
    stdout: "inherit",
    stderr: "inherit",
  });
  const status = await child.exited;
  if (status !== 0) {
    throw new Error(`${command[0]} exited with status ${status}`);
  }
}

const originalLanguage = process.env.ZAPP_NATIVE_LANG;
process.env.ZAPP_NATIVE_LANG = "z";
try {
  await compileNative({
    root: spike,
    buildFile: "",
    buildConfigFile: "",
    nativeDir: resolve(repository, "native"),
    output: host,
    optimize: true,
    target: "macos",
  });
} finally {
  if (originalLanguage === undefined) delete process.env.ZAPP_NATIVE_LANG;
  else process.env.ZAPP_NATIVE_LANG = originalLanguage;
}
await run([host, "{\"message\":\"héllo from Zapp\"}"]);
