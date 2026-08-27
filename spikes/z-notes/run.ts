import { resolve } from "node:path";
import { compileNative } from "../../cli/src/native";
import {
  createConfigContext,
  loadConfig,
} from "../../cli/src/config";

const spike = import.meta.dir;
const repository = resolve(spike, "../..");
const output = resolve(spike, "build", "zapp-z-webview");

async function run(
  command: string[],
  env?: Record<string, string | undefined>,
  workingDirectory = repository,
): Promise<void> {
  const child = Bun.spawn(command, {
    cwd: workingDirectory,
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
const config = await loadConfig(
  spike,
  createConfigContext(spike, "build", "macos"),
);

await run(["bunx", "vite", "build"], undefined, spike);

const originalLanguage = process.env.ZAPP_NATIVE_LANG;
const originalHost = process.env.ZAPP_Z_HOST;
let compiled = false;
process.env.ZAPP_NATIVE_LANG = "z";
process.env.ZAPP_Z_HOST = "desktop";
try {
  await compileNative({
    root: spike,
    buildFile: "",
    buildConfigFile: "",
    nativeDir: resolve(repository, "native"),
    output,
    optimize: true,
    target: "macos",
    config,
  });
  compiled = true;
} finally {
  if (originalLanguage === undefined) delete process.env.ZAPP_NATIVE_LANG;
  else process.env.ZAPP_NATIVE_LANG = originalLanguage;
  if (originalHost === undefined) delete process.env.ZAPP_Z_HOST;
  else process.env.ZAPP_Z_HOST = originalHost;
}

await run(
  [output],
  smoke ? { ...process.env, ZAPP_Z_DESKTOP_SMOKE: "1" } : process.env,
);
