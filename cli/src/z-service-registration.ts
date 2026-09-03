import path from "node:path";
import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import type { ZServiceManifest, ZServiceMetadata } from "./z-service-bindings";
import {
  zServiceAdapterFactoryName,
  zServiceUsesAsyncDispatch,
} from "./z-service-dispatcher";

const generatedModuleSpecifier = "zapp/generated/service-dispatchers";

export interface ZServiceRegistrationTarget {
  marker: string;
  synchronous: string;
  asynchronous: string;
  synchronousWithLifecycle: string;
  asynchronousWithLifecycle: string;
  generatedModulePackage: string | null;
}

export interface ZGeneratedBuildModule {
  specifier: string;
  source: string;
  packageName: string | null;
}

export interface ZGeneratedBuildCallAdapter {
  source: string;
  offset: number;
  target: string;
  replacement: string;
  argument: number;
  adapterModule: string;
  adapterExport: string;
}

export interface ZGeneratedBuildContribution {
  modules: readonly ZGeneratedBuildModule[];
  callAdapters: readonly ZGeneratedBuildCallAdapter[];
}

const applicationRegistrationTarget: ZServiceRegistrationTarget = {
  marker: "ApplicationServices.register",
  synchronous: "ApplicationServices.registerGenerated",
  asynchronous: "ApplicationServices.registerGeneratedAsync",
  synchronousWithLifecycle:
    "ApplicationServices.registerGeneratedWithLifecycle",
  asynchronousWithLifecycle:
    "ApplicationServices.registerGeneratedAsyncWithLifecycle",
  generatedModulePackage: "zapp",
};

function relativeBuildPath(fromFile: string, target: string): string {
  let relative = path.relative(path.dirname(fromFile), target).replaceAll(path.sep, "/");
  if (!relative.startsWith(".")) relative = `./${relative}`;
  return relative;
}

function registrationMethodName(
  service: ZServiceMetadata,
  target: ZServiceRegistrationTarget,
): string {
  if (service.registration.method !== target.marker) {
    throw new Error(
      `[zapp] cannot generate runtime registration for unsupported method `
      + `${JSON.stringify(service.registration.method)}`,
    );
  }
  if (zServiceUsesAsyncDispatch(service)) {
    return service.lifecycle
      ? target.asynchronousWithLifecycle
      : target.asynchronous;
  }
  return service.lifecycle
    ? target.synchronousWithLifecycle
    : target.synchronous;
}

export async function generateZServiceRegistrationOverlay(
  manifest: ZServiceManifest,
  generatedModule: string,
  outputPath: string,
  target: ZServiceRegistrationTarget = applicationRegistrationTarget,
  additional: ZGeneratedBuildContribution = { modules: [], callAdapters: [] },
): Promise<string> {
  for (const service of manifest.services) registrationMethodName(service, target);
  const services = [...manifest.services].sort((left, right) => (
      left.registration.module.localeCompare(right.registration.module)
      || left.registration.offset - right.registration.offset
    ));
  const sourceHashes = new Map<string, string>();
  for (const modulePath of new Set([
    ...services.map((service) => service.registration.module),
    ...additional.callAdapters.map((adapter) => adapter.source),
  ])) {
    const source = await readFile(modulePath, "utf8");
    sourceHashes.set(
      modulePath,
      createHash("sha256").update(source).digest("hex"),
    );
  }
  const callAdapters = services.map((service) => ({
    source: relativeBuildPath(outputPath, service.registration.module),
    sourceHash: sourceHashes.get(service.registration.module)!,
    offset: service.registration.offset,
    target: service.registration.method,
    replacement: registrationMethodName(service, target),
    argument: 1,
    adapter: {
      module: generatedModuleSpecifier,
      export: zServiceAdapterFactoryName(service.name),
    },
  })).concat(additional.callAdapters.map((adapter) => ({
    source: relativeBuildPath(outputPath, adapter.source),
    sourceHash: sourceHashes.get(adapter.source)!,
    offset: adapter.offset,
    target: adapter.target,
    replacement: adapter.replacement,
    argument: adapter.argument,
    adapter: {
      module: adapter.adapterModule,
      export: adapter.adapterExport,
    },
  })));
  const generatedModuleDeclaration = {
    source: relativeBuildPath(outputPath, generatedModule),
    ...(target.generatedModulePackage === null
      ? {}
      : { package: target.generatedModulePackage }),
  };
  const modules = Object.fromEntries([
    [generatedModuleSpecifier, generatedModuleDeclaration],
    ...additional.modules.map((module) => [module.specifier, {
      source: relativeBuildPath(outputPath, module.source),
      ...(module.packageName === null ? {} : { package: module.packageName }),
    }] as const),
  ]);
  const overlay = {
    schemaVersion: 1,
    modules,
    callAdapters,
  };
  await mkdir(path.dirname(outputPath), { recursive: true });
  await writeFile(outputPath, `${JSON.stringify(overlay, null, 2)}\n`, "utf8");
  return outputPath;
}
