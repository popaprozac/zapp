import path from "node:path";
import { createHash } from "node:crypto";
import { existsSync, realpathSync } from "node:fs";
import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import type { BuildTarget } from "./build-target";
import type { ResolvedConfig } from "./config";
import type { ResolvedCapabilityProfile } from "./capabilities";
import {
  renderZApplicationWorkerCatalog,
  renderZApplicationWorkerStartup,
  zEmbeddedApplicationWorkerPath,
  type ResolvedApplicationWorker,
} from "./application-workers";
import type { ZServiceManifest } from "./z-service-bindings";
import type {
  ZProgramMetadata,
  ZWorkerProtocolManifest,
  ZWorkerProtocolUse,
} from "./z-program-metadata";
import { isPermissionAllowed, resolvePermissions } from "./permissions";
import {
  buildWebviewInjections,
  type BuiltWebviewInjection,
} from "./webview-injections";

export interface ZCompilerIdentity {
  languageVersion: string;
  compilerRevision: string;
  compilerApi: number;
}

export type ZNativeHost = "desktop" | "bridge";

export interface ZNativeStageFile {
  source: string;
  destination: string;
}

export interface ZNativeLinkRequirements {
  includeDirectories?: string[];
  directories?: string[];
  libraries?: string[];
  frameworks?: string[];
}

interface ZCompilerContract extends ZCompilerIdentity {}

interface BuildNativeZOptions {
  root: string;
  nativeDir: string;
  output: string;
  optimize: boolean;
  target: BuildTarget;
  config: ResolvedConfig;
  /** Development frontend origin. Absent means packaged embedded assets. */
  devUrl?: string;
  preparedServices?: PreparedZFrontendServices;
}

export interface PrepareZFrontendServicesOptions {
  root: string;
  nativeDir: string;
  config: Pick<ResolvedConfig, "applicationWorkers">;
}

export interface PreparedZFrontendServices {
  bindingPath: string;
  manifest: ZServiceManifest;
  programMetadataSource: string;
  inputHashes: Record<string, string>;
  workerBindingPath: string;
  workerProtocols: ZWorkerProtocolManifest[];
}

interface ZFrontendServicesCache {
  schemaVersion: 1;
  compiler: ZCompilerIdentity;
  inputHashes: Record<string, string>;
}

export interface ZModulePathMapping {
  source: string;
  destination: string;
}

function renderZCapabilityProfiles(
  profiles: ResolvedCapabilityProfile[],
): string {
  const statements: string[] = ["  let profiles = Map<String, CapabilityProfile>();"];
  profiles.forEach((profile, index) => {
    statements.push(`  let permissions${index} = Array<String>();`);
    for (const permission of profile.permissions) {
      statements.push(`  permissions${index}.push(${JSON.stringify(permission)});`);
    }
    statements.push(`  let serviceMethods${index} = Array<String>();`);
    for (const method of profile.serviceMethods) {
      statements.push(`  serviceMethods${index}.push(${JSON.stringify(method)});`);
    }
    statements.push(`  let workerIds${index} = Array<String>();`);
    for (const workerId of profile.workerIds) {
      statements.push(`  workerIds${index}.push(${JSON.stringify(workerId)});`);
    }
    statements.push(
      `  profiles.set(${JSON.stringify(profile.name)}, CapabilityProfile({`,
      `    permissions: permissions${index}.freeze(),`,
      `    serviceMethods: serviceMethods${index}.freeze(),`,
      `    workerIds: workerIds${index}.freeze(),`,
      "  }));",
    );
  });
  statements.push(
    "  return new ApplicationCapabilities({ profiles: profiles.freeze() });",
  );
  return statements.join("\n");
}

export function renderZConfiguredDesktopSmoke(enabled: boolean): string {
  const source = [
    ...(enabled ? [
      'import smoke from "desktop-smoke.h";',
      'import Foundation from "Foundation/Foundation.h";',
    ] : []),
    'import WebKit from "WebKit/WebKit.h";',
    'import { thread } from "std/thread";',
    "",
    "internal function configuredMacOSApplicationSmokeMode(): boolean {",
    `  return ${enabled};`,
    "}",
    "",
    "internal function startConfiguredWindowSmokeSupport(",
    "  in windowId: String,",
    "  nativeId: i32,",
    "  in webView: WebKit.WKWebView,",
    "  in contentController: WebKit.WKUserContentController",
    "): void on thread.main {",
  ];
  if (enabled) {
    source.push(
      "  const nativeWindowId: Foundation.NSString = copy windowId;",
      "  smoke.zapp_desktop_smoke_start_window(",
      "    in webView,",
      "    in contentController,",
      "    in nativeWindowId,",
      "    nativeId",
      "  );",
    );
  }
  source.push(
    "}",
    "",
    "internal function observeConfiguredWebViewResponse(",
    "  in webView: WebKit.WKWebView,",
    "  nativeId: i32,",
    "  activeWindowCount: usize,",
    "  in payload: String,",
    "  requestId: u64,",
    "  development: boolean,",
    "  ok: boolean",
    "): void {",
  );
  if (enabled) {
    source.push(
      "  const nativePayload: Foundation.NSString = copy payload;",
      "  smoke.zapp_desktop_smoke_observe_response(",
      "    in webView,",
      "    nativeId,",
      "    activeWindowCount,",
      "    in nativePayload,",
      "    requestId,",
      "    development,",
      "    ok",
      "  );",
    );
  }
  source.push("}", "");
  return source.join("\n");
}

export function renderZApplicationMetadata(
  config: ResolvedConfig,
  capabilityProfiles: ResolvedCapabilityProfile[] = [{
    name: "default",
    permissions: [],
    serviceMethods: [],
    workerIds: [],
  }],
  applicationWorkers: readonly ResolvedApplicationWorker[] = [],
  workerStartupProbe?: { channel: string; payload: string },
): string {
  return `// AUTO-GENERATED by zapp CLI. Do not edit.
import { Map } from "std/collections";
import {
  ApplicationCapabilities,
  CapabilityProfile,
} from "./application-capabilities.zs";
import { ApplicationMetadata } from "./application-metadata.zs";
import { ApplicationPermissions } from "./application-permissions.zs";
import {
  ApplicationWorkerCatalog,
  ApplicationWorkerEngine,
  ApplicationWorkerRestartPolicy,
  ConfiguredApplicationWorker,
} from "./worker/configuration.zs";
import {
  ApplicationWorkerAsyncServiceHandler,
  ApplicationWorkerControl,
  ApplicationWorkerMessageHandler,
  ApplicationWorkerServiceCancelHandler,
  ApplicationWorkers,
  startEmptyApplicationWorkers,
} from "./worker/application-workers.zs";
import { ApplicationWorkerLifecycleHandler } from "./worker/lifecycle.zs";
import { Services } from "./services.zs";
${applicationWorkers.length > 0 ? `import embed from "std/embed";
import { WorkerModule } from "./worker/types.zs";
import { startZjsApplicationWorker } from "./worker/zjs/runtime.zs";` : ""}

export function configuredApplicationMetadata(): ApplicationMetadata {
  return ApplicationMetadata({
    name: ${JSON.stringify(config.name)},
    identifier: ${JSON.stringify(config.identifier)},
    version: ${JSON.stringify(config.version)},
  });
}

export function configuredApplicationPermissions(): ApplicationPermissions {
  return ApplicationPermissions({
    windowCreate: ${isPermissionAllowed(
      "window:create",
      resolvePermissions(config.permissions),
    )},
    menu: ${isPermissionAllowed(
      "menu",
      resolvePermissions(config.permissions),
    )},
    clipboardRead: ${
      config.permissions !== undefined
      && isPermissionAllowed(
        "clipboard:read",
        resolvePermissions(config.permissions),
      )
    },
    clipboardWrite: ${
      config.permissions !== undefined
      && isPermissionAllowed(
        "clipboard:write",
        resolvePermissions(config.permissions),
      )
    },
    notifications: ${
      config.permissions !== undefined
      && isPermissionAllowed(
        "notifications",
        resolvePermissions(config.permissions),
      )
    },
  });
}

export function configuredApplicationCapabilities(): ApplicationCapabilities {
${renderZCapabilityProfiles(capabilityProfiles)}
}

${renderZApplicationWorkerCatalog(applicationWorkers)}

${renderZApplicationWorkerStartup(applicationWorkers, workerStartupProbe)}
`;
}

export function renderZWebviewBootstrapConfig(
  config: ResolvedConfig,
  target: BuildTarget,
): string {
  const resolved = resolvePermissions(config.permissions);
  const platform = target === "macos"
    ? "macos"
    : target === "windows"
      ? "windows"
      : "ios";
  return `globalThis[Symbol.for("zapp.bootstrapConfig")]=${JSON.stringify({
    permissions: {
      platform,
      active: resolved.active,
      allow: resolved.allow,
    },
  })};\n`;
}

export function parseZCompilerIdentity(output: string): ZCompilerIdentity {
  const match = output.trim().match(
    /^z\s+(\S+)\s+revision\s+(\S+)\s+compiler-api\s+(\d+)$/,
  );
  if (!match) {
    throw new Error(
      `[zapp] could not parse Z compiler identity ${JSON.stringify(output.trim())}. ` +
      "Zapp requires a compiler that supports `z version`.",
    );
  }
  return {
    languageVersion: match[1],
    compilerRevision: match[2],
    compilerApi: Number(match[3]),
  };
}

export function validateZCompilerIdentity(
  expected: ZCompilerIdentity,
  actual: ZCompilerIdentity,
  contractPath: string,
): void {
  const differences: string[] = [];
  if (actual.languageVersion !== expected.languageVersion) {
    differences.push(`language ${actual.languageVersion} (expected ${expected.languageVersion})`);
  }
  if (actual.compilerRevision !== expected.compilerRevision) {
    differences.push(`revision ${actual.compilerRevision} (expected ${expected.compilerRevision})`);
  }
  if (actual.compilerApi !== expected.compilerApi) {
    differences.push(`compiler API ${actual.compilerApi} (expected ${expected.compilerApi})`);
  }
  if (differences.length > 0) {
    throw new Error(
      `[zapp] incompatible Z compiler: ${differences.join(", ")}. ` +
      `Use the compiler pinned by ${contractPath} or update the contract after validating Zapp.`,
    );
  }
}

export function resolveZCompiler(repositoryRoot: string): string {
  if (process.env.ZAPP_Z_COMPILER) return process.env.ZAPP_Z_COMPILER;
  const sibling = path.resolve(repositoryRoot, "../z-lang/.z-cache/bootstrap/z");
  return existsSync(sibling) ? sibling : "z";
}

export function resolveZCompilerCommand(repositoryRoot: string): string[] {
  const driver = process.env.ZAPP_Z_COMPILER_DRIVER ?? "native";
  if (driver === "native") return [resolveZCompiler(repositoryRoot)];
  if (driver !== "stage0") {
    throw new Error(
      `[zapp] ZAPP_Z_COMPILER_DRIVER must be "native" or "stage0", not ${JSON.stringify(driver)}.`,
    );
  }
  const entry = path.resolve(repositoryRoot, "../z-lang/compiler/src/cli.ts");
  if (!existsSync(entry)) {
    throw new Error(
      `[zapp] the Stage 0 Z driver was requested, but ${entry} does not exist. ` +
      "Use the sibling z-lang development workspace or select the native driver.",
    );
  }
  return [process.execPath, entry];
}

export function resolveZNativeHost(value: string | undefined): ZNativeHost {
  const host = value ?? "desktop";
  if (host !== "desktop" && host !== "bridge") {
    throw new Error(
      `[zapp] ZAPP_Z_HOST must be "desktop" or "bridge", not ${JSON.stringify(host)}.`,
    );
  }
  return host;
}

export function zNativeStageFiles(host: ZNativeHost): ZNativeStageFile[] {
  return [
    {
      source: "framework/bridge/zapp_router.h",
      destination: "zapp_router.h",
    },
    {
      source: "framework/bridge/zapp_router.h.zd",
      destination: "zapp_router.h.zd",
    },
    ...(host === "desktop" ? [
      {
        source: "framework/platform/macos/desktop-smoke.h",
        destination: "desktop-smoke.h",
      },
      {
        source: "framework/platform/macos/desktop-smoke.h.zd",
        destination: "desktop-smoke.h.zd",
      },
      {
        source: "framework/platform/macos/desktop-smoke.m",
        destination: "desktop-smoke.m",
      },
    ] : [{
      source: "testing/bridge-host.c",
      destination: "host.c",
    }]),
  ];
}

export function zNativeEntry(host: ZNativeHost): string {
  return host === "desktop" ? "main.zs" : "embedded.zs";
}

export function renderZNativeManifest(
  host: ZNativeHost,
  entry: string,
  nativeDirectory = ".",
  packageDirectory?: string,
  application: ZNativeLinkRequirements = {},
  desktopSmokeSupport = false,
  minimumVersion = "14.0",
): string {
  const unique = (values: string[]): string[] => [...new Set(values)];
  const target = host === "desktop"
    ? {
      name: "zapp_core",
      entry,
      platform: "macos",
      minimumVersion,
      includeDirectories: unique([
        nativeDirectory,
        ...(application.includeDirectories ?? []),
      ]),
      link: {
        directories: unique([
          nativeDirectory,
          ...(application.directories ?? []),
        ]),
        libraries: unique([
          ...(desktopSmokeSupport ? ["zapp_desktop_smoke"] : []),
          "compression",
          ...(application.libraries ?? []),
        ]),
        frameworks: unique(application.frameworks ?? []),
      },
    }
    : {
      kind: "static-library",
      name: "zapp_core",
      entry,
      platform: "macos",
      minimumVersion,
      includeDirectories: [nativeDirectory],
      runtime: { initialize: "initializeApplication" },
    };
  const dependencies = packageDirectory
    ? { zapp: { path: packageDirectory } }
    : undefined;
  return `${JSON.stringify({
    ...(dependencies ? { dependencies } : {}),
    target,
  }, null, 2)}\n`;
}

function manifestStringList(value: unknown, label: string): string[] {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.some((item) => typeof item !== "string")) {
    throw new Error(`[zapp] ${label} in zapp/z.json must be an array of strings`);
  }
  return value;
}

async function readZApplicationLinkRequirements(
  appSource: string,
): Promise<ZNativeLinkRequirements> {
  const manifestPath = path.join(appSource, "z.json");
  if (!existsSync(manifestPath)) return {};
  const manifest = JSON.parse(await readFile(manifestPath, "utf8")) as {
    target?: {
      includeDirectories?: unknown;
      link?: {
        directories?: unknown;
        libraries?: unknown;
        frameworks?: unknown;
      };
    };
  };
  const absolute = (values: string[]): string[] => values.map((directory) => (
    path.isAbsolute(directory) ? directory : path.resolve(appSource, directory)
  ));
  return {
    includeDirectories: absolute(manifestStringList(
      manifest.target?.includeDirectories,
      "target.includeDirectories",
    )),
    directories: absolute(manifestStringList(
      manifest.target?.link?.directories,
      "target.link.directories",
    )),
    libraries: manifestStringList(
      manifest.target?.link?.libraries,
      "target.link.libraries",
    ),
    frameworks: manifestStringList(
      manifest.target?.link?.frameworks,
      "target.link.frameworks",
    ),
  };
}

function mergeZNativeLinkRequirements(
  left: ZNativeLinkRequirements,
  right: ZNativeLinkRequirements,
): ZNativeLinkRequirements {
  const unique = (values: string[]): string[] => [...new Set(values)];
  return {
    includeDirectories: unique([
      ...(left.includeDirectories ?? []),
      ...(right.includeDirectories ?? []),
    ]),
    directories: unique([
      ...(left.directories ?? []),
      ...(right.directories ?? []),
    ]),
    libraries: unique([
      ...(left.libraries ?? []),
      ...(right.libraries ?? []),
    ]),
    frameworks: unique([
      ...(left.frameworks ?? []),
      ...(right.frameworks ?? []),
    ]),
  };
}

async function resolveZjsDevelopmentArtifacts(
  repositoryRoot: string,
  minimumVersion: string,
): Promise<{
  includeDirectory: string;
  libraryDirectory: string;
}> {
  const overriddenLibrary = process.env.ZAPP_ZJS_LIBRARY;
  const zjsRepository = path.resolve(repositoryRoot, "../zjs");
  const library = overriddenLibrary
    ?? path.join(zjsRepository, "build/libzjs.a");
  const includeDirectory = process.env.ZAPP_ZJS_INCLUDE
    ?? path.resolve(path.dirname(library), "../include");
  if (!overriddenLibrary && existsSync(path.join(zjsRepository, "Makefile"))) {
    const targetStamp = path.join(zjsRepository, "build/.macos-deployment-target");
    const recordedTarget = existsSync(targetStamp)
      ? (await readFile(targetStamp, "utf8")).trim()
      : "";
    if (!existsSync(library) || recordedTarget !== minimumVersion) {
      console.log(
        `[zapp] building ZJS development archive for macOS ${minimumVersion}`,
      );
      await run([
        "make",
        "stdlib-embed",
        "lib-static",
        "ZJS_TIER=minimal",
        `MACOSX_DEPLOYMENT_TARGET=${minimumVersion}`,
      ], zjsRepository);
    }
  }
  if (!existsSync(library) || !existsSync(path.join(includeDirectory, "zjs.h"))) {
    throw new Error(
      "[zapp] a configured native Z application worker requires the ZJS "
      + `development artifacts at ${library} and ${path.join(includeDirectory, "zjs.h")}. `
      + "Build the sibling zjs repository or set ZAPP_ZJS_LIBRARY and ZAPP_ZJS_INCLUDE.",
    );
  }
  return { includeDirectory, libraryDirectory: path.dirname(library) };
}

async function stageZApplicationWorkerRuntime(
  options: BuildNativeZOptions,
  source: string,
  stage: string,
  stagedFramework: string,
  workers: readonly ResolvedApplicationWorker[],
): Promise<ZNativeLinkRequirements> {
  if (workers.length === 0) return {};

  for (const [index, worker] of workers.entries()) {
    const builtModule = resolveZApplicationWorkerArtifact(
      options.root,
      options.config.assetDir,
      worker.moduleUrl,
      options.devUrl !== undefined,
    );
    if (!existsSync(builtModule)) {
      throw new Error(
        `[zapp] bundled application worker ${JSON.stringify(worker.id)} was not found at `
        + `${builtModule}; build the frontend worker artifacts before the native core`,
      );
    }
    const embeddedPath = zEmbeddedApplicationWorkerPath(worker, index).replace(/^\.\//, "");
    const destination = path.join(stagedFramework, embeddedPath);
    await mkdir(path.dirname(destination), { recursive: true });
    await cp(builtModule, destination);
  }

  const minimumVersion = options.config.macos?.minimumSystemVersion ?? "14.0";
  const zjs = await resolveZjsDevelopmentArtifacts(
    path.resolve(options.nativeDir, ".."),
    minimumVersion,
  );
  const adapterDirectory = path.join(source, "framework", "worker", "zjs");
  const adapterObject = path.join(stage, "zapp_worker_zjs.o");
  const adapterArchive = path.join(stage, "libzapp_worker_zjs.a");
  await run([
    "clang",
    "-O2",
    `-mmacosx-version-min=${minimumVersion}`,
    "-I",
    zjs.includeDirectory,
    "-I",
    adapterDirectory,
    "-I",
    path.join(source, "framework", "worker"),
    "-fobjc-arc",
    "-c",
    path.join(adapterDirectory, "zapp_worker_zjs.m"),
    "-o",
    adapterObject,
  ], options.root);
  await run(["ar", "rcs", adapterArchive, adapterObject], options.root);
  await cp(
    path.join(adapterDirectory, "zapp_worker_zjs.h"),
    path.join(stage, "zapp_worker_zjs.h"),
  );
  await cp(
    path.join(source, "framework", "worker", "zapp_worker_runtime.h"),
    path.join(stage, "zapp_worker_runtime.h"),
  );

  return {
    includeDirectories: [stage],
    directories: [stage, zjs.libraryDirectory],
    libraries: ["zapp_worker_zjs", "zjs", "z"],
    frameworks: ["Foundation", "Security"],
  };
}

export function resolveZApplicationWorkerArtifact(
  root: string,
  assetDirectory: string,
  moduleUrl: string,
  development: boolean,
): string {
  const relativeModule = moduleUrl.replace(/^\/+/, "");
  if (!development) {
    return path.join(path.resolve(root, assetDirectory), relativeModule);
  }

  const workerPrefix = "_workers/";
  if (!relativeModule.startsWith(workerPrefix)) {
    throw new Error(
      `[zapp] development application worker URL ${JSON.stringify(moduleUrl)} `
      + `must begin with "/${workerPrefix}"`,
    );
  }
  return path.join(
    root,
    ".zapp",
    "workers",
    relativeModule.slice(workerPrefix.length),
  );
}

export function resolveZFrontendOrigin(devUrl?: string): string {
  if (!devUrl) return "zapp://app/";
  const parsed = new URL(devUrl);
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    throw new Error(
      `[zapp] the frontend development URL must use http or https, not ${JSON.stringify(parsed.protocol)}.`,
    );
  }
  parsed.hash = "";
  parsed.search = "";
  if (!parsed.pathname.endsWith("/")) parsed.pathname += "/";
  return parsed.toString();
}

export function renderZConfiguredWebView(
  bootstrap: string,
  frontendOrigin: string,
  injections: BuiltWebviewInjection[],
): string {
  const development = frontendOrigin.startsWith("http://")
    || frontendOrigin.startsWith("https://");
  let source = `// AUTO-GENERATED by zapp CLI. Do not edit.\n\n`;
  source += `internal struct ConfiguredWebViewInjection {\n`;
  source += `  profile: String;\n`;
  source += `  source: String;\n`;
  source += `  phase: i32;\n`;
  source += `}\n\n`;
  source += `internal function configuredFrontendOrigin(): String {\n`;
  source += `  return ${JSON.stringify(frontendOrigin)};\n`;
  source += `}\n\n`;
  source += `internal function configuredFrontendIsDevelopment(): boolean {\n`;
  source += `  return ${development};\n`;
  source += `}\n\n`;
  source += `internal function configuredWebViewBootstrap(): String {\n`;
  source += `  return ${JSON.stringify(bootstrap)};\n`;
  source += `}\n\n`;
  source += `internal function configuredWebViewInjectionCount(): usize {\n`;
  source += `  return ${injections.length};\n`;
  source += `}\n\n`;
  source += `internal function configuredWebViewInjectionAtIndex(\n`;
  source += `  index: usize\n`;
  source += `): Option<ConfiguredWebViewInjection> {\n`;
  injections.forEach((entry, index) => {
    source += `  if (index == ${index}) {\n`;
    source += `    return Option.some(ConfiguredWebViewInjection({\n`;
    source += `      profile: ${JSON.stringify(entry.profile)},\n`;
    source += `      source: ${JSON.stringify(entry.source)},\n`;
    source += `      phase: ${entry.phase},\n`;
    source += `    }));\n`;
    source += `  }\n`;
  });
  source += `  return Option.none;\n`;
  source += `}\n`;
  return source;
}

async function run(command: string[], cwd: string, capture = false): Promise<string> {
  const process = Bun.spawn(command, {
    cwd,
    stdout: capture ? "pipe" : "inherit",
    stderr: capture ? "pipe" : "inherit",
  });
  const stdout = capture ? await new Response(process.stdout).text() : "";
  const stderr = capture ? await new Response(process.stderr).text() : "";
  const status = await process.exited;
  if (status !== 0) {
    throw new Error(
      `[zapp] command failed (${status}): ${command.join(" ")}` +
      (stderr.trim() ? `\n${stderr.trim()}` : ""),
    );
  }
  return stdout;
}

export async function assertZCompilerContract(
  compiler: string[],
  contractPath: string,
  cwd: string,
): Promise<ZCompilerIdentity> {
  const expected = JSON.parse(await readFile(contractPath, "utf8")) as ZCompilerContract;
  const actual = parseZCompilerIdentity(await run([...compiler, "version"], cwd, true));
  validateZCompilerIdentity(expected, actual, contractPath);
  return actual;
}

async function hashFile(file: string): Promise<string> {
  return createHash("sha256").update(await readFile(file)).digest("hex");
}

export function zProgramInputPaths(
  metadata: ZProgramMetadata,
  explicitInputs: string[] = [],
): string[] {
  const inputs = new Set(metadata.modules.map((module) => module.path));
  const visitedDirectories = new Set<string>();
  for (const module of metadata.modules) {
    let directory = path.dirname(module.path);
    while (!visitedDirectories.has(directory)) {
      visitedDirectories.add(directory);
      const manifest = path.join(directory, "z.json");
      if (existsSync(manifest)) inputs.add(manifest);
      const parent = path.dirname(directory);
      if (parent === directory) break;
      directory = parent;
    }
  }
  for (const input of explicitInputs) {
    if (existsSync(input)) inputs.add(input);
  }
  return [...inputs].sort();
}

async function hashZProgramInputs(
  metadata: ZProgramMetadata,
  explicitInputs: string[] = [],
): Promise<Record<string, string>> {
  return Object.fromEntries(await Promise.all(
    zProgramInputPaths(metadata, explicitInputs).map(async (input) => (
      [input, await hashFile(input)] as const
    )),
  ));
}

export async function preparedZServicesAreCurrent(
  prepared: Pick<PreparedZFrontendServices, "inputHashes">,
): Promise<boolean> {
  for (const [inputPath, expectedHash] of Object.entries(prepared.inputHashes)) {
    if (!existsSync(inputPath) || await hashFile(inputPath) !== expectedHash) return false;
  }
  return true;
}

function sameZCompilerIdentity(
  left: ZCompilerIdentity,
  right: ZCompilerIdentity,
): boolean {
  return left.languageVersion === right.languageVersion
    && left.compilerRevision === right.compilerRevision
    && left.compilerApi === right.compilerApi;
}

function parseZFrontendServicesCache(source: string): ZFrontendServicesCache {
  const parsed = JSON.parse(source) as Partial<ZFrontendServicesCache>;
  if (
    parsed.schemaVersion !== 1
    || !parsed.compiler
    || typeof parsed.compiler.languageVersion !== "string"
    || typeof parsed.compiler.compilerRevision !== "string"
    || !Number.isInteger(parsed.compiler.compilerApi)
    || !parsed.inputHashes
    || typeof parsed.inputHashes !== "object"
    || Array.isArray(parsed.inputHashes)
    || Object.values(parsed.inputHashes).some((hash) => typeof hash !== "string")
  ) {
    throw new Error("[zapp] malformed cached Z service metadata");
  }
  return parsed as ZFrontendServicesCache;
}

function cacheCoversZProgramInputs(
  metadata: ZProgramMetadata,
  inputHashes: Record<string, string>,
  explicitInputs: string[],
): boolean {
  const expected = zProgramInputPaths(metadata, explicitInputs);
  const cached = Object.keys(inputHashes).sort();
  return expected.every((input) => cached.includes(input));
}

function rebaseZModulePath(
  modulePath: string,
  mappings: ZModulePathMapping[],
): string {
  const canonical = (value: string): string => {
    try {
      return realpathSync(value);
    } catch {
      return path.resolve(value);
    }
  };
  const resolvedModule = canonical(modulePath);
  for (const mapping of mappings) {
    const resolvedSource = canonical(mapping.source);
    const relative = path.relative(resolvedSource, resolvedModule);
    if (!relative.startsWith("..") && !path.isAbsolute(relative)) {
      return path.join(mapping.destination, relative);
    }
  }
  throw new Error(
    `[zapp] prepared Z service module ${modulePath} is outside the staged source graph`,
  );
}

/** Rebase checked source metadata into the isolated native build workspace. */
export function rebaseZServiceManifest(
  manifest: ZServiceManifest,
  mappings: ZModulePathMapping[],
): ZServiceManifest {
  const rebaseType = <T extends { module: string }>(value: T): T => ({
    ...value,
    module: rebaseZModulePath(value.module, mappings),
  });
  return {
    ...manifest,
    types: manifest.types.map(rebaseType),
    enums: manifest.enums.map(rebaseType),
    errors: manifest.errors.map(rebaseType),
    services: manifest.services.map((service) => ({
      ...service,
      module: rebaseZModulePath(service.module, mappings),
      registration: {
        ...service.registration,
        module: rebaseZModulePath(service.registration.module, mappings),
      },
    })),
  };
}

export function rebaseZWorkerProtocolManifest(
  manifest: ZWorkerProtocolManifest,
  mappings: ZModulePathMapping[],
): ZWorkerProtocolManifest {
  const rebaseType = <T extends { module: string }>(value: T): T => ({
    ...value,
    module: rebaseZModulePath(value.module, mappings),
  });
  return {
    ...manifest,
    module: rebaseZModulePath(manifest.module, mappings),
    types: manifest.types.map(rebaseType),
    enums: manifest.enums.map(rebaseType),
  };
}

export function rebaseZWorkerProtocolUses(
  uses: readonly ZWorkerProtocolUse[],
  mappings: ZModulePathMapping[],
): ZWorkerProtocolUse[] {
  return uses.map((use) => ({
    ...use,
    module: rebaseZModulePath(use.module, mappings),
  }));
}

/**
 * Generate the WebView-facing TypeScript service module before Vite starts.
 *
 * The native build reuses this checked source graph when every module hash is
 * still current, and falls back to metadata collection from its isolated
 * staged workspace when it is not. This gives Vite and TypeScript a real
 * generated module on the first clean `zapp dev` / `zapp build` invocation
 * without normally paying for semantic metadata twice.
 */
export async function prepareZFrontendServices(
  options: PrepareZFrontendServicesOptions,
): Promise<PreparedZFrontendServices> {
  const appSource = path.join(options.root, "zapp");
  const sourceEntry = path.join(appSource, zNativeEntry(
    resolveZNativeHost(process.env.ZAPP_Z_HOST),
  ));
  if (!existsSync(sourceEntry)) {
    throw new Error(
      `[zapp] could not generate Z service bindings because ${sourceEntry} does not exist.`,
    );
  }

  const repositoryRoot = path.resolve(options.nativeDir, "..");
  const compiler = resolveZCompilerCommand(repositoryRoot);
  const contractPath = path.join(options.nativeDir, "z", "compiler-contract.json");
  const compilerIdentity = await assertZCompilerContract(
    compiler,
    contractPath,
    options.root,
  );

  const {
    deriveZServiceManifest,
    deriveZWorkerProtocolManifest,
    parseZProgramMetadata,
  } = await import("./z-program-metadata");
  const { generateZServiceBindings } = await import("./z-service-bindings");
  const { generateZWorkerBindings } = await import("./z-worker-bindings");
  const outputDirectory = path.join(options.root, ".zapp", "generated");
  await mkdir(outputDirectory, { recursive: true });
  const programMetadataPath = path.join(outputDirectory, "program.zmeta.json");
  const cachePath = path.join(outputDirectory, "program.zmeta.cache.json");
  const explicitInputs = [contractPath];
  let programMetadataSource: string;
  let programMetadata: ZProgramMetadata;
  let manifest: ZServiceManifest;
  let inputHashes: Record<string, string>;

  try {
    const cache = parseZFrontendServicesCache(await readFile(cachePath, "utf8"));
    if (!sameZCompilerIdentity(cache.compiler, compilerIdentity)) {
      throw new Error("cached Z compiler identity changed");
    }
    programMetadataSource = await readFile(programMetadataPath, "utf8");
    programMetadata = parseZProgramMetadata(programMetadataSource);
    if (!cacheCoversZProgramInputs(programMetadata, cache.inputHashes, explicitInputs)) {
      throw new Error("cached Z service inputs are incomplete");
    }
    manifest = deriveZServiceManifest(programMetadata);
    inputHashes = cache.inputHashes;
    if (!await preparedZServicesAreCurrent({ inputHashes })) {
      throw new Error("cached Z service inputs changed");
    }
    console.log("[zapp] reused persistent checked Z service metadata");
  } catch {
    programMetadataSource = await run(
      [...compiler, "metadata", appSource],
      options.root,
      true,
    );
    programMetadata = parseZProgramMetadata(programMetadataSource);
    manifest = deriveZServiceManifest(programMetadata);
    inputHashes = await hashZProgramInputs(programMetadata, explicitInputs);
    await writeFile(programMetadataPath, programMetadataSource, "utf8");
    const cache: ZFrontendServicesCache = {
      schemaVersion: 1,
      compiler: compilerIdentity,
      inputHashes,
    };
    await writeFile(cachePath, `${JSON.stringify(cache, null, 2)}\n`, "utf8");
  }

  await writeFile(
    path.join(outputDirectory, "services.zmeta.json"),
    `${JSON.stringify(manifest, null, 2)}\n`,
    "utf8",
  );
  const bindingPath = await generateZServiceBindings(manifest, outputDirectory);
  const workerProtocols: ZWorkerProtocolManifest[] = [];
  for (const [workerId, authored] of Object.entries(
    options.config.applicationWorkers ?? {},
  )) {
    const entry = typeof authored === "string" ? { script: authored } : authored;
    if (!entry.protocol) continue;
    const protocolModule = path.resolve(options.root, entry.protocol.module);
    if (!existsSync(protocolModule)) {
      throw new Error(
        `[zapp] worker ${JSON.stringify(workerId)} protocol module does not exist: `
        + protocolModule,
      );
    }
    const protocolMetadataSource = await run(
      [...compiler, "metadata", protocolModule],
      options.root,
      true,
    );
    const protocolMetadata = parseZProgramMetadata(protocolMetadataSource);
    Object.assign(inputHashes, await hashZProgramInputs(protocolMetadata));
    workerProtocols.push(deriveZWorkerProtocolManifest(
      protocolMetadata,
      workerId,
      protocolModule,
      entry.protocol.type,
    ));
  }
  await writeFile(cachePath, `${JSON.stringify({
    schemaVersion: 1,
    compiler: compilerIdentity,
    inputHashes,
  }, null, 2)}\n`, "utf8");
  await writeFile(
    path.join(outputDirectory, "workers.zmeta.json"),
    `${JSON.stringify({ schemaVersion: 1, protocols: workerProtocols }, null, 2)}\n`,
    "utf8",
  );
  const workerBindingPath = await generateZWorkerBindings(
    workerProtocols,
    outputDirectory,
  );
  return {
    bindingPath,
    manifest,
    programMetadataSource,
    inputHashes,
    workerBindingPath,
    workerProtocols,
  };
}

export async function buildNativeZ(options: BuildNativeZOptions): Promise<void> {
  if (options.target !== "macos") {
    throw new Error(
      `[zapp] the Phase 0 Z native core currently supports target "macos", not ${JSON.stringify(options.target)}.`,
    );
  }
  const minimumVersion = options.config.macos?.minimumSystemVersion ?? "14.0";

  const source = path.join(options.nativeDir, "z");
  const appSource = path.join(options.root, "zapp");
  const repositoryRoot = path.resolve(options.nativeDir, "..");
  const stage = path.join(options.root, ".zapp", "z-native-core");
  const workspace = path.join(stage, "workspace");
  const host = resolveZNativeHost(process.env.ZAPP_Z_HOST);
  const desktop = host === "desktop";
  const desktopSmokeSupport = desktop
    && process.env.ZAPP_Z_DESKTOP_SMOKE_SUPPORT === "1";
  const sourceEntry = path.join(appSource, zNativeEntry(host));
  if (!existsSync(sourceEntry)) {
    throw new Error(
      `[zapp] could not find the Z application entry ${sourceEntry}. ` +
      `Expected ${zNativeEntry(host)} under the project's zapp/ directory.`,
    );
  }
  const applicationLinkRequirements = await readZApplicationLinkRequirements(
    appSource,
  );
  const appRelative = path.relative(repositoryRoot, appSource);
  if (appRelative.startsWith("..") || path.isAbsolute(appRelative)) {
    throw new Error(
      `[zapp] the current Z application spike must live inside ${repositoryRoot}; ` +
      `package-resolved framework imports are the next productization layer.`,
    );
  }
  await mkdir(stage, { recursive: true });
  for (const obsolete of [
    "desktop.m",
    "zapp_frontend_assets.c",
    "zapp_frontend_assets.o",
    "zapp_application_host.o",
    "zapp_asset_bridge.o",
    "zapp_frontend_config.c",
    "zapp_frontend_config.o",
    "zapp_webview_bootstrap.c",
    "zapp_webview_bootstrap.o",
    "zapp_webview_bridge.o",
    "zapp_webview_injections.c",
    "zapp_webview_injections.o",
    "zapp_window_bridge.o",
  ]) {
    await rm(path.join(stage, obsolete), { force: true });
  }
  await rm(workspace, { recursive: true, force: true });
  const stagedFramework = path.join(workspace, "native", "z", "framework");
  await cp(
    path.join(source, "framework"),
    stagedFramework,
    { recursive: true },
  );
  await cp(
    path.join(source, "api"),
    path.join(workspace, "native", "z", "api"),
    { recursive: true },
  );
  await cp(
    path.join(source, "z.json"),
    path.join(workspace, "native", "z", "z.json"),
  );
  await writeFile(
    path.join(stagedFramework, "configured-application.zs"),
    renderZApplicationMetadata(options.config),
    "utf8",
  );
  if (desktop) {
    const { generateAssetManifestZ } = await import("./assets");
    await generateAssetManifestZ(
      options.root,
      options.config.assetDir,
      {
        embed: !options.devUrl,
        compress: options.config.compressAssets !== false,
        outputPath: path.join(
          stagedFramework,
          "platform",
          "macos",
          "configured-assets.zs",
        ),
      },
    );
  }
  const stagedAppSource = path.join(workspace, appRelative);
  await cp(appSource, stagedAppSource, { recursive: true });
  // The source-local manifest exists for direct editor/check context. The
  // isolated workspace has a generated root manifest that additionally owns
  // its generated host archive, so it must remain the single build authority.
  await rm(path.join(stagedAppSource, "z.json"), { force: true });
  const appEntry = path.join(stagedAppSource, zNativeEntry(host));
  for (const file of zNativeStageFiles(host)) {
    const destination = path.join(stage, file.destination);
    await mkdir(path.dirname(destination), { recursive: true });
    await cp(path.join(source, file.source), destination);
  }
  await writeFile(
    path.join(stage, "z.json"),
    renderZNativeManifest(
      host,
      appEntry,
      stage,
      path.join(workspace, "native", "z"),
      applicationLinkRequirements,
      desktopSmokeSupport,
      minimumVersion,
    ),
    "utf8",
  );

  const compiler = resolveZCompilerCommand(
    path.resolve(options.nativeDir, ".."),
  );
  const identity = await assertZCompilerContract(
    compiler,
    path.join(source, "compiler-contract.json"),
    options.root,
  );
  console.log(
    `[zapp] Z core compiler ${identity.languageVersion} ` +
    `(revision ${identity.compilerRevision}, API ${identity.compilerApi}, ` +
    `${process.env.ZAPP_Z_COMPILER_DRIVER === "stage0" ? "Stage 0" : "native"} driver)`,
  );

  const { resolveBootstrapDir } = await import("./paths");
  const { generateZServiceBindings } = await import("./z-service-bindings");
  const { generateZServiceDispatchers } = await import(
    "./z-service-dispatcher"
  );
  const { generateZServiceRegistrationOverlay } = await import(
    "./z-service-registration"
  );
  const {
    generateZWorkerProtocolAdapters,
    zWorkerProtocolBuildContribution,
  } = await import("./z-worker-native");
  const {
    deriveZServiceManifest,
    deriveZWorkerProtocolManifest,
    deriveZWorkerProtocolUses,
    parseZProgramMetadata,
  } = await import("./z-program-metadata");
  const { resolveCapabilityProfiles } = await import("./capabilities");
  const { resolveApplicationWorkers } = await import("./application-workers");
  const { bundleWebviewBootstrapRaw } = await import(
    path.join(resolveBootstrapDir(), "codegen.ts")
  );
  let programMetadataSource: string;
  let programMetadata: ZProgramMetadata;
  let serviceManifest: ZServiceManifest;
  let workerProtocols: ZWorkerProtocolManifest[];
  const stagedMappings = [
    { source: appSource, destination: stagedAppSource },
    { source, destination: path.join(workspace, "native", "z") },
  ];
  const preparedCurrent = options.preparedServices
    ? await preparedZServicesAreCurrent(options.preparedServices)
    : false;
  if (options.preparedServices && preparedCurrent) {
    programMetadataSource = options.preparedServices.programMetadataSource;
    programMetadata = parseZProgramMetadata(programMetadataSource);
    serviceManifest = rebaseZServiceManifest(
      options.preparedServices.manifest,
      stagedMappings,
    );
    workerProtocols = options.preparedServices.workerProtocols.map((protocol) => (
      rebaseZWorkerProtocolManifest(protocol, stagedMappings)
    ));
    console.log("[zapp] reused checked Z service metadata from the frontend preflight");
  } else {
    if (options.preparedServices) {
      console.log("[zapp] Z sources changed after frontend preflight; refreshing metadata");
    }
    programMetadataSource = await run(
      [...compiler, "metadata", stage],
      options.root,
      true,
    );
    programMetadata = parseZProgramMetadata(programMetadataSource);
    serviceManifest = deriveZServiceManifest(programMetadata);
    workerProtocols = [];
    for (const [workerId, authored] of Object.entries(
      options.config.applicationWorkers ?? {},
    )) {
      const entry = typeof authored === "string" ? { script: authored } : authored;
      if (!entry.protocol) continue;
      const originalModule = path.resolve(options.root, entry.protocol.module);
      const protocolModule = rebaseZModulePath(originalModule, stagedMappings);
      const metadataSource = await run(
        [...compiler, "metadata", protocolModule],
        options.root,
        true,
      );
      workerProtocols.push(deriveZWorkerProtocolManifest(
        parseZProgramMetadata(metadataSource),
        workerId,
        protocolModule,
        entry.protocol.type,
      ));
    }
  }
  const originalWorkerUses = deriveZWorkerProtocolUses(
    programMetadata,
    options.preparedServices && preparedCurrent
      ? options.preparedServices.workerProtocols
      : workerProtocols,
  );
  const workerUses = options.preparedServices && preparedCurrent
    ? rebaseZWorkerProtocolUses(originalWorkerUses, stagedMappings)
    : originalWorkerUses;
  await writeFile(
    path.join(stage, "program.zmeta.json"),
    programMetadataSource,
    "utf8",
  );
  const capabilityProfiles = resolveCapabilityProfiles(
    options.config,
    serviceManifest,
  );
  const applicationWorkers = resolveApplicationWorkers(
    options.config,
    capabilityProfiles,
  );
  const workerLinkRequirements = await stageZApplicationWorkerRuntime(
    options,
    source,
    stage,
    stagedFramework,
    applicationWorkers,
  );
  if (applicationWorkers.length > 0) {
    await writeFile(
      path.join(stage, "z.json"),
      renderZNativeManifest(
        host,
        appEntry,
        stage,
        path.join(workspace, "native", "z"),
        mergeZNativeLinkRequirements(
          applicationLinkRequirements,
          workerLinkRequirements,
        ),
        desktopSmokeSupport,
        minimumVersion,
      ),
      "utf8",
    );
  }
  await writeFile(
    path.join(stagedFramework, "configured-application.zs"),
    renderZApplicationMetadata(
      options.config,
      capabilityProfiles,
      applicationWorkers,
      process.env.ZAPP_APPLICATION_WORKER_BENCHMARK === "1"
        ? {
            channel: "benchmark",
            payload: JSON.stringify({
              directIterations: 10_000,
              publicIterations: 1_000,
              samples: 5,
            }),
          }
        : process.env.ZAPP_APPLICATION_WORKER_SMOKE === "1"
          ? { channel: "ping", payload: "configured-worker-smoke" }
          : undefined,
    ),
    "utf8",
  );
  await writeFile(
    path.join(stage, "capabilities.zmeta.json"),
    `${JSON.stringify({ schemaVersion: 1, profiles: capabilityProfiles }, null, 2)}\n`,
    "utf8",
  );
  await writeFile(
    path.join(stage, "application-workers.zmeta.json"),
    `${JSON.stringify({ schemaVersion: 1, workers: applicationWorkers }, null, 2)}\n`,
    "utf8",
  );
  await writeFile(
    path.join(stage, "services.zmeta.json"),
    `${JSON.stringify(serviceManifest, null, 2)}\n`,
    "utf8",
  );
  const dispatcher = await generateZServiceDispatchers(
    serviceManifest,
    {
      outputPath: path.join(stage, "generated", "service-dispatchers.zs"),
      serviceContractModule: path.join(
        workspace,
        "native",
        "z",
        "framework",
        "service-contract.zs",
      ),
      servicesModule: path.join(
        workspace,
        "native",
        "z",
        "framework",
        "services.zs",
      ),
      asyncServiceContractModule: path.join(
        workspace,
        "native",
        "z",
        "framework",
        "async-service-contract.zs",
      ),
      serviceLifecycleContractModule: path.join(
        workspace,
        "native",
        "z",
        "api",
        "zapp",
        "service.zs",
      ),
    },
  );
  await run([...compiler, "check", dispatcher], options.root, true);
  console.log(`[zapp] checked generated Z service dispatch ${dispatcher}`);
  const workerProtocolModule = path.join(
    stage,
    "generated",
    "worker-protocols.zs",
  );
  const workerContribution = workerProtocols.length === 0
    ? { modules: [], callAdapters: [] }
    : zWorkerProtocolBuildContribution(
      workerProtocols,
      workerUses,
      await generateZWorkerProtocolAdapters(workerProtocols, {
        outputPath: workerProtocolModule,
        workerModule: path.join(
          stagedFramework,
          "worker",
          "worker-manager.zs",
        ),
      }),
    );
  const registrationOverlay = await generateZServiceRegistrationOverlay(
    serviceManifest,
    dispatcher,
    path.join(stage, "generated", "service-registration.zbuild.json"),
    undefined,
    workerContribution,
  );
  console.log(`[zapp] generated checked Z service registration ${registrationOverlay}`);
  const generatedBinding = await generateZServiceBindings(
    serviceManifest,
    path.join(options.root, ".zapp", "generated"),
  );
  console.log(`[zapp] generated typed Z service bindings ${generatedBinding}`);
  const bootstrapSource = renderZWebviewBootstrapConfig(options.config, options.target)
    + await bundleWebviewBootstrapRaw();
  if (desktop) {
    await writeFile(
      path.join(
        stagedFramework,
        "platform",
        "macos",
        "configured-smoke.zs",
      ),
      renderZConfiguredDesktopSmoke(desktopSmokeSupport),
      "utf8",
    );
    const injectionEntries = await buildWebviewInjections(
      options.root,
      options.config.webviewInject,
      options.optimize,
    );
    await writeFile(
      path.join(
        stagedFramework,
        "platform",
        "macos",
        "configured-webview.zs",
      ),
      renderZConfiguredWebView(
        bootstrapSource,
        resolveZFrontendOrigin(options.devUrl),
        injectionEntries,
      ),
      "utf8",
    );
  }

  const clang = process.env.CC || "clang";
  if (desktop && desktopSmokeSupport) {
    const desktopSmokeObject = path.join(stage, "zapp_desktop_smoke.o");
    const desktopArchive = path.join(stage, "libzapp_desktop_smoke.a");
    await run([
      clang,
      "-fobjc-arc",
      "-fblocks",
      `-mmacosx-version-min=${minimumVersion}`,
      options.optimize ? "-Oz" : "-O0",
      "-Wall",
      "-Wextra",
      "-Werror",
      "-I",
      stage,
      "-c",
      path.join(stage, "desktop-smoke.m"),
      "-o",
      desktopSmokeObject,
    ], options.root);
    await rm(desktopArchive, { force: true });
    await run([
      "ar",
      "rcs",
      desktopArchive,
      desktopSmokeObject,
    ], options.root);
  }

  await run(
    [
      ...compiler,
      "build",
      stage,
      "--generated",
      registrationOverlay,
      ...(options.optimize ? ["--release"] : []),
    ],
    options.root,
  );

  await mkdir(path.dirname(options.output), { recursive: true });
  if (desktop) {
    await cp(path.join(stage, "build", "zapp_core"), options.output);
    return;
  }
  const archive = path.join(stage, "build", "libzapp_core.a");
  const headerDir = path.join(stage, "build");
  await run([
    clang,
    "-std=c11",
    `-mmacosx-version-min=${minimumVersion}`,
    options.optimize ? "-Oz" : "-O0",
    "-Wall",
    "-Wextra",
    "-Werror",
    "-I",
    headerDir,
    path.join(stage, "host.c"),
    archive,
    "-o",
    options.output,
  ], options.root);
}
