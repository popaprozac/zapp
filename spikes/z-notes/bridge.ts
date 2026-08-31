import { resolve } from "node:path";
import { compileNative } from "../../cli/src/native";
import {
  createConfigContext,
  loadConfig,
} from "../../cli/src/config";

const spike = import.meta.dir;
const repository = resolve(spike, "../..");
const build = resolve(spike, "build");
const host = resolve(build, "zapp-message-bridge-host");
const config = await loadConfig(
  spike,
  createConfigContext(spike, "build", "macos"),
);
// This regression host intentionally exposes no application services. Let the
// compiler derive its empty default capability surface instead of inheriting
// Z Notes' service-specific production profiles.
config.capabilityProfiles = undefined;

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
const originalHost = process.env.ZAPP_Z_HOST;
process.env.ZAPP_NATIVE_LANG = "z";
process.env.ZAPP_Z_HOST = "bridge";
try {
  await compileNative({
    root: spike,
    buildFile: "",
    buildConfigFile: "",
    nativeDir: resolve(repository, "native"),
    output: host,
    optimize: true,
    target: "macos",
    config,
  });
} finally {
  if (originalLanguage === undefined) delete process.env.ZAPP_NATIVE_LANG;
  else process.env.ZAPP_NATIVE_LANG = originalLanguage;
  if (originalHost === undefined) delete process.env.ZAPP_Z_HOST;
  else process.env.ZAPP_Z_HOST = originalHost;
}
await run([
  host,
  '{"t":1,"id":18446744073709551615,"m":"__zapp:ping","a":{"message":"héllo from Zapp"}}',
  '{"message":"héllo from Zapp"}',
]);
