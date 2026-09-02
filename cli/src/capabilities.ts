import type { CapabilityProfileConfig, ResolvedConfig } from "./config";
import {
  isPermissionAllowed,
  PERMISSION_IDS,
  resolvePermissions,
  type ZappPermission,
} from "./permissions";
import type { ZServiceManifest } from "./z-service-bindings";

export interface ResolvedCapabilityProfile {
  name: string;
  permissions: ZappPermission[];
  serviceMethods: string[];
  workerIds: string[];
}

function allServiceMethods(manifest: ZServiceManifest): string[] {
  return manifest.services.flatMap((service) => (
    service.methods.map((method) => `${service.name}.${method.name}`)
  ));
}

function expandServiceSelectors(
  profileName: string,
  selectors: string[],
  manifest: ZServiceManifest,
): string[] {
  const exactMethods = new Set(allServiceMethods(manifest));
  const services = new Map(
    manifest.services.map((service) => [
      service.name,
      service.methods.map((method) => `${service.name}.${method.name}`),
    ]),
  );
  const expanded: string[] = [];
  const seen = new Set<string>();
  for (const selector of selectors) {
    const selected = services.get(selector)
      ?? (exactMethods.has(selector) ? [selector] : undefined);
    if (!selected) {
      const choices = [...services.keys(), ...exactMethods].sort();
      throw new Error(
        `[zapp] security.capabilities.${profileName}.services contains unknown selector ` +
        `${JSON.stringify(selector)}. Registered selectors: ${choices.join(", ") || "<none>"}`,
      );
    }
    for (const method of selected) {
      if (seen.has(method)) continue;
      seen.add(method);
      expanded.push(method);
    }
  }
  return expanded;
}

function expandedPermissions(
  configured: ZappPermission[] | undefined,
): ZappPermission[] {
  const resolved = resolvePermissions(configured ?? []);
  return PERMISSION_IDS.filter((permission) => (
    isPermissionAllowed(permission, resolved)
  ));
}

export function resolveCapabilityProfiles(
  config: Pick<
    ResolvedConfig,
    "permissions" | "capabilityProfiles" | "applicationWorkers"
  >,
  manifest: ZServiceManifest,
): ResolvedCapabilityProfile[] {
  const profiles = config.capabilityProfiles;
  if (!profiles) {
    const global = resolvePermissions(config.permissions);
    return [{
      name: "default",
      permissions: PERMISSION_IDS.filter((permission) => (
        isPermissionAllowed(permission, global)
      )),
      serviceMethods: allServiceMethods(manifest),
      workerIds: Object.keys(config.applicationWorkers ?? {}),
    }];
  }
  return Object.entries(profiles).map(([name, profile]: [string, CapabilityProfileConfig]) => ({
    name,
    permissions: expandedPermissions(profile.permissions),
    serviceMethods: expandServiceSelectors(name, profile.services ?? [], manifest),
    workerIds: [...(profile.workers ?? [])],
  }));
}
