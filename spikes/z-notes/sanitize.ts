import { rm, writeFile, mkdir } from "node:fs/promises";
import { resolve } from "node:path";
import {
  runBoundedCommand,
  type BoundedCommandResult,
} from "../../cli/src/bounded-process";
import { compileNative } from "../../cli/src/native";
import {
  createConfigContext,
  loadConfig,
} from "../../cli/src/config";

const spike = import.meta.dir;
const repository = resolve(spike, "../..");
const outputDirectory = resolve(spike, "build", "sanitizers");
const stagedCore = resolve(spike, ".zapp", "z-native-core");
const generatedCore = resolve(stagedCore, ".z-cache", "build", "zapp_core.m");
const generatedHeaderDirectory = resolve(stagedCore, "build");
const desktopHost = resolve(stagedCore, "desktop.m");
const desktopSmoke = resolve(stagedCore, "desktop-smoke.m");
const bootstrap = resolve(stagedCore, "zapp_webview_bootstrap.c");
const assets = resolve(stagedCore, "zapp_frontend_assets.c");
const frontendConfig = resolve(stagedCore, "zapp_frontend_config.c");
const injections = resolve(stagedCore, "zapp_webview_injections.c");
const expectedEvidence = "visible WebView round trip window=1";
const expectedPayload = 'payload={"id":"1","title":"WebView note"}';

async function runBounded(
  command: string[],
  timeoutMs: number,
  options: {
    env?: Record<string, string>;
    allowFailure?: boolean;
  } = {},
): Promise<BoundedCommandResult> {
  const result = await runBoundedCommand(command, {
    cwd: repository,
    timeoutMs,
    env: options.env,
  });
  if (!options.allowFailure && (result.timedOut || result.status !== 0)) {
    const reason = result.timedOut
      ? `timed out after ${timeoutMs} ms`
      : `exited with status ${result.status}`;
    throw new Error(
      `${command[0]} ${reason}: ${command.join(" ")}` +
      (result.stderr.trim() ? `\n${result.stderr.trim()}` : ""),
    );
  }
  return result;
}

async function buildInstrumented(
  name: string,
  sanitizerFlags: string[],
): Promise<string> {
  const object = resolve(outputDirectory, `${name}.o`);
  const archive = resolve(outputDirectory, `lib${name}.a`);
  const executable = resolve(outputDirectory, name);
  await rm(archive, { force: true });
  await runBounded([
    "clang",
    "-x", "objective-c",
    "-fobjc-arc",
    "-fblocks",
    "-mmacosx-version-min=14.0",
    "-O1",
    "-g",
    "-Wall",
    "-Wextra",
    "-Werror",
    ...sanitizerFlags,
    "-I", stagedCore,
    "-I", generatedHeaderDirectory,
    "-c", generatedCore,
    "-o", object,
  ], 120_000);
  await runBounded(["ar", "rcs", archive, object], 30_000);
  await runBounded([
    "clang",
    "-fobjc-arc",
    "-fblocks",
    "-mmacosx-version-min=14.0",
    "-O1",
    "-g",
    "-Wall",
    "-Wextra",
    "-Werror",
    "-DZAPP_DESKTOP_SMOKE_SUPPORT=1",
    ...sanitizerFlags,
    "-I", generatedHeaderDirectory,
    desktopHost,
    desktopSmoke,
    bootstrap,
    assets,
    frontendConfig,
    injections,
    archive,
    "-framework", "AppKit",
    "-framework", "WebKit",
    "-framework", "CoreFoundation",
    "-lcompression",
    "-o", executable,
  ], 120_000);
  return executable;
}

function requireLifecycleEvidence(
  result: BoundedCommandResult,
  label: string,
): void {
  if (
    !result.stdout.includes(expectedEvidence)
    || !result.stdout.includes(expectedPayload)
  ) {
    throw new Error(
      `${label} did not complete the WebKit lifecycle` +
      (result.stdout.trim() ? `\nstdout:\n${result.stdout.trim()}` : "") +
      (result.stderr.trim() ? `\nstderr:\n${result.stderr.trim()}` : ""),
    );
  }
  if (/runtime error:|message sent to deallocated instance/i.test(result.stderr)) {
    throw new Error(`${label} reported a sanitizer failure:\n${result.stderr}`);
  }
}

await mkdir(outputDirectory, { recursive: true });

const originalLanguage = process.env.ZAPP_NATIVE_LANG;
const originalHost = process.env.ZAPP_Z_HOST;
const originalSmokeSupport = process.env.ZAPP_Z_DESKTOP_SMOKE_SUPPORT;
const config = await loadConfig(
  spike,
  createConfigContext(spike, "build", "macos"),
);
process.env.ZAPP_NATIVE_LANG = "z";
process.env.ZAPP_Z_HOST = "desktop";
process.env.ZAPP_Z_DESKTOP_SMOKE_SUPPORT = "1";
try {
  await compileNative({
    root: spike,
    buildFile: "",
    buildConfigFile: "",
    nativeDir: resolve(repository, "native"),
    output: resolve(outputDirectory, "ordinary"),
    optimize: true,
    target: "macos",
    config,
  });
} finally {
  if (originalLanguage === undefined) delete process.env.ZAPP_NATIVE_LANG;
  else process.env.ZAPP_NATIVE_LANG = originalLanguage;
  if (originalHost === undefined) delete process.env.ZAPP_Z_HOST;
  else process.env.ZAPP_Z_HOST = originalHost;
  if (originalSmokeSupport === undefined) {
    delete process.env.ZAPP_Z_DESKTOP_SMOKE_SUPPORT;
  } else {
    process.env.ZAPP_Z_DESKTOP_SMOKE_SUPPORT = originalSmokeSupport;
  }
}

const undefinedBehavior = await buildInstrumented("webview-ubsan", [
  "-fsanitize=undefined",
  "-fno-sanitize-recover=all",
]);
const undefinedBehaviorResult = await runBounded(
  [undefinedBehavior],
  20_000,
  {
    env: {
      NSZombieEnabled: "YES",
      ZAPP_Z_DESKTOP_SMOKE: "1",
    },
  },
);
requireLifecycleEvidence(undefinedBehaviorResult, "UBSan + Objective-C zombies");
process.stdout.write(undefinedBehaviorResult.stdout);
console.log("[zapp] UBSan and Objective-C zombie lifecycle check passed");

const addressProbeSource = resolve(outputDirectory, "asan-probe.c");
const addressProbe = resolve(outputDirectory, "asan-probe");
await writeFile(addressProbeSource, "int main(void) { return 0; }\n", "utf8");
await runBounded([
  "clang",
  "-fsanitize=address",
  addressProbeSource,
  "-o", addressProbe,
], 30_000);
const addressProbeResult = await runBounded(
  [addressProbe],
  3_000,
  { allowFailure: true },
);

if (addressProbeResult.timedOut) {
  console.log(
    "[zapp] ASan runtime unavailable: its empty startup probe timed out; " +
    "the child was killed and the WebKit ASan run was skipped",
  );
} else if (addressProbeResult.status !== 0) {
  throw new Error(
    `ASan startup probe failed with status ${addressProbeResult.status}` +
    (addressProbeResult.stderr.trim()
      ? `\n${addressProbeResult.stderr.trim()}`
      : ""),
  );
} else {
  const address = await buildInstrumented("webview-asan", [
    "-fsanitize=address",
  ]);
  const addressResult = await runBounded(
    [address],
    20_000,
  {
    env: {
      ASAN_OPTIONS: "halt_on_error=1:detect_leaks=0",
      ZAPP_Z_DESKTOP_SMOKE: "1",
    },
  },
  );
  requireLifecycleEvidence(addressResult, "ASan");
  console.log("[zapp] ASan lifecycle check passed");
}
