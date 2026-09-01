import type {
  ApplicationWorkerConfig,
  ResolvedConfig,
  WorkerEngineName,
} from "./config";
import type { ZappPermission } from "./permissions";
import type { ResolvedCapabilityProfile } from "./capabilities";

export interface ResolvedApplicationWorker {
  id: string;
  script: string;
  name?: string;
  engine?: WorkerEngineName;
  bytecode: boolean;
  restart: false | {
    maxRetries: number;
    withinMs: number;
  };
  capabilities: string[];
  permissions: ZappPermission[];
  serviceMethods: string[];
}

function normalizeEntry(
  entry: string | ApplicationWorkerConfig,
): ApplicationWorkerConfig {
  return typeof entry === "string" ? { script: entry } : entry;
}

/**
 * Freeze each application's configured worker authority into build metadata.
 * Runtime JavaScript receives the result; it never chooses profile names.
 */
export function resolveApplicationWorkers(
  config: Pick<ResolvedConfig, "applicationWorkers">,
  profiles: ResolvedCapabilityProfile[],
): ResolvedApplicationWorker[] {
  const profileByName = new Map(profiles.map((profile) => [profile.name, profile]));
  return Object.entries(config.applicationWorkers ?? {}).map(([id, authored]) => {
    const entry = normalizeEntry(authored);
    const capabilities = [...(entry.capabilities ?? [])];
    const permissions: ZappPermission[] = [];
    const serviceMethods: string[] = [];
    const seenPermissions = new Set<ZappPermission>();
    const seenServiceMethods = new Set<string>();
    for (const name of capabilities) {
      const profile = profileByName.get(name);
      if (!profile) {
        throw new Error(
          `[zapp] application worker ${JSON.stringify(id)} references unknown ` +
          `security capability profile ${JSON.stringify(name)}`,
        );
      }
      for (const permission of profile.permissions) {
        if (seenPermissions.has(permission)) continue;
        seenPermissions.add(permission);
        permissions.push(permission);
      }
      for (const method of profile.serviceMethods) {
        if (seenServiceMethods.has(method)) continue;
        seenServiceMethods.add(method);
        serviceMethods.push(method);
      }
    }
    const restart = entry.restart
      ? {
          maxRetries: entry.restart.maxRetries ?? 3,
          withinMs: entry.restart.withinMs ?? 60_000,
        }
      : false;
    return {
      id,
      script: entry.script,
      ...(entry.name === undefined ? {} : { name: entry.name }),
      ...(entry.engine === undefined ? {} : { engine: entry.engine }),
      bytecode: entry.bytecode ?? false,
      restart,
      capabilities,
      permissions,
      serviceMethods,
    };
  });
}
