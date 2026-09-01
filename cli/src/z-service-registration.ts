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

const applicationRegistrationTarget: ZServiceRegistrationTarget = {
  marker: "ApplicationServicesBuilder.register",
  synchronous: "ApplicationServicesBuilder.registerGenerated",
  asynchronous: "ApplicationServicesBuilder.registerGeneratedAsync",
  synchronousWithLifecycle:
    "ApplicationServicesBuilder.registerGeneratedWithLifecycle",
  asynchronousWithLifecycle:
    "ApplicationServicesBuilder.registerGeneratedAsyncWithLifecycle",
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
): Promise<string> {
  for (const service of manifest.services) registrationMethodName(service, target);
  const services = [...manifest.services].sort((left, right) => (
      left.registration.module.localeCompare(right.registration.module)
      || left.registration.offset - right.registration.offset
    ));
  const sourceHashes = new Map<string, string>();
  for (const modulePath of new Set(services.map((service) => service.registration.module))) {
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
  }));
  const generatedModuleDeclaration = {
    source: relativeBuildPath(outputPath, generatedModule),
    ...(target.generatedModulePackage === null
      ? {}
      : { package: target.generatedModulePackage }),
  };
  const overlay = {
    schemaVersion: 1,
    modules: {
      [generatedModuleSpecifier]: generatedModuleDeclaration,
    },
    callAdapters,
  };
  await mkdir(path.dirname(outputPath), { recursive: true });
  await writeFile(outputPath, `${JSON.stringify(overlay, null, 2)}\n`, "utf8");
  return outputPath;
}
