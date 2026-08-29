import path from "node:path";
import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import type { ZServiceManifest, ZServiceMetadata } from "./z-service-bindings";
import {
  zServiceAdapterFactoryName,
  zServiceUsesAsyncDispatch,
} from "./z-service-dispatcher";

const generatedRegistration = "ApplicationServicesBuilder.register";
const generatedModuleSpecifier = "zapp/generated/service-dispatchers";

function relativeBuildPath(fromFile: string, target: string): string {
  let relative = path.relative(path.dirname(fromFile), target).replaceAll(path.sep, "/");
  if (!relative.startsWith(".")) relative = `./${relative}`;
  return relative;
}

function registrationMethodName(service: ZServiceMetadata): string {
  if (service.registration.method !== generatedRegistration) {
    throw new Error(
      `[zapp] cannot generate runtime registration for unsupported method `
      + `${JSON.stringify(service.registration.method)}`,
    );
  }
  if (zServiceUsesAsyncDispatch(service)) {
    return service.lifecycle
      ? "registerGeneratedAsyncWithLifecycle"
      : "registerGeneratedAsync";
  }
  return service.lifecycle
    ? "registerGeneratedWithLifecycle"
    : "registerGenerated";
}

export async function generateZServiceRegistrationOverlay(
  manifest: ZServiceManifest,
  generatedModule: string,
  outputPath: string,
): Promise<string> {
  for (const service of manifest.services) registrationMethodName(service);
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
    replacement: `ApplicationServicesBuilder.${registrationMethodName(service)}`,
    argument: 1,
    adapter: {
      module: generatedModuleSpecifier,
      export: zServiceAdapterFactoryName(service.name),
    },
  }));
  const overlay = {
    schemaVersion: 1,
    modules: {
      [generatedModuleSpecifier]: {
        source: relativeBuildPath(outputPath, generatedModule),
        package: "zapp",
      },
    },
    callAdapters,
  };
  await mkdir(path.dirname(outputPath), { recursive: true });
  await writeFile(outputPath, `${JSON.stringify(overlay, null, 2)}\n`, "utf8");
  return outputPath;
}
