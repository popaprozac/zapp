import { resolve } from "node:path";
import { compileNative } from "../../cli/src/native";

const spike = import.meta.dir;
const repository = resolve(spike, "../..");
const output = resolve(spike, "build", "zapp-z-webview");

async function run(
  command: string[],
  env?: Record<string, string | undefined>,
): Promise<void> {
  const child = Bun.spawn(command, {
    cwd: repository,
    env,
    stdout: "inherit",
    stderr: "inherit",
  });
  const status = await child.exited;
  if (status !== 0) {
    throw new Error(`${command[0]} exited with status ${status}`);
  }
}

const smoke = process.argv.includes("--smoke");

const originalLanguage = process.env.ZAPP_NATIVE_LANG;
const originalHost = process.env.ZAPP_Z_HOST;
const originalCompilerDriver = process.env.ZAPP_Z_COMPILER_DRIVER;
process.env.ZAPP_NATIVE_LANG = "z";
process.env.ZAPP_Z_HOST = "desktop";
// TaskScope is implemented by the Stage 0 compiler today. Keep this explicit
// until the fixed-point native backend reaches the same lowering tier.
process.env.ZAPP_Z_COMPILER_DRIVER = "stage0";
try {
  await compileNative({
    root: spike,
    buildFile: "",
    buildConfigFile: "",
    nativeDir: resolve(repository, "native"),
    output,
    optimize: true,
    target: "macos",
  });
} finally {
  if (originalLanguage === undefined) delete process.env.ZAPP_NATIVE_LANG;
  else process.env.ZAPP_NATIVE_LANG = originalLanguage;
  if (originalHost === undefined) delete process.env.ZAPP_Z_HOST;
  else process.env.ZAPP_Z_HOST = originalHost;
  if (originalCompilerDriver === undefined) {
    delete process.env.ZAPP_Z_COMPILER_DRIVER;
  } else process.env.ZAPP_Z_COMPILER_DRIVER = originalCompilerDriver;
}

await run(
  [output],
  smoke
    ? { ...process.env, ZAPP_Z_DESKTOP_SMOKE: "1" }
    : process.env,
);
