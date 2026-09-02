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
  moduleUrl: string;
  name?: string;
  engine: WorkerEngineName;
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
 * Native Z and frontend bindings consume the same resolved evidence; runtime
 * JavaScript never chooses profile names or expands its own authority.
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
      moduleUrl: `/_workers/_headless_${id}.${entry.bytecode ? "zbc" : "mjs"}`,
      ...(entry.name === undefined ? {} : { name: entry.name }),
      engine: entry.engine ?? "zjs",
      bytecode: entry.bytecode ?? false,
      restart,
      capabilities,
      permissions,
      serviceMethods,
    };
  });
}

const zWorkerEngineCases: Record<WorkerEngineName, string> = {
  "zjs": "zjs",
  "bare-jsc": "bareJsc",
  "bare-v8": "bareV8",
  "bare-quickjs": "bareQuickJs",
  "bare-mqjs": "bareMicroQuickJs",
  "bare-hermes": "bareHermes",
};

function renderZStringArray(
  variable: string,
  values: readonly string[],
): string[] {
  return [
    `  let ${variable} = Array<String>();`,
    ...values.map((value) => `  ${variable}.push(${JSON.stringify(value)});`),
  ];
}

/** Render the immutable, runtime-consumed Z application-worker catalog. */
export function renderZApplicationWorkerCatalog(
  workers: readonly ResolvedApplicationWorker[],
): string {
  const lines = [
    "export function configuredApplicationWorkers(): ApplicationWorkerCatalog {",
    "  let workers = Array<ConfiguredApplicationWorker>();",
  ];
  workers.forEach((worker, index) => {
    const prefix = `worker${index}`;
    lines.push(
      ...renderZStringArray(`${prefix}Capabilities`, worker.capabilities),
      ...renderZStringArray(`${prefix}Permissions`, worker.permissions),
      ...renderZStringArray(`${prefix}ServiceMethods`, worker.serviceMethods),
      "  workers.push(ConfiguredApplicationWorker({",
      `    id: ${JSON.stringify(worker.id)},`,
      `    source: ${JSON.stringify(worker.script)},`,
      `    moduleUrl: ${JSON.stringify(worker.moduleUrl)},`,
      `    name: ${JSON.stringify(worker.name ?? "")},`,
      `    engine: ApplicationWorkerEngine.${zWorkerEngineCases[worker.engine]},`,
      `    bytecode: ${worker.bytecode},`,
      "    restart: ApplicationWorkerRestartPolicy({",
      `      enabled: ${worker.restart !== false},`,
      `      maxRetries: ${worker.restart === false ? 0 : worker.restart.maxRetries},`,
      `      withinMilliseconds: ${worker.restart === false ? 0 : worker.restart.withinMs},`,
      "    }),",
      `    capabilities: ${prefix}Capabilities.freeze(),`,
      `    permissions: ${prefix}Permissions.freeze(),`,
      `    serviceMethods: ${prefix}ServiceMethods.freeze(),`,
      "  }));",
    );
  });
  lines.push(
    "  return ApplicationWorkerCatalog({ entries: workers.freeze() });",
    "}",
  );
  return lines.join("\n");
}

function embeddedWorkerExtension(worker: ResolvedApplicationWorker): string {
  return worker.bytecode ? "zbc" : "mjs";
}

export function zEmbeddedApplicationWorkerPath(
  worker: ResolvedApplicationWorker,
  index: number,
): string {
  return `./worker/generated/application-worker-${index}.${embeddedWorkerExtension(worker)}`;
}

/** Render application-worker startup without exposing engine details publicly. */
export function renderZApplicationWorkerStartup(
  workers: readonly ResolvedApplicationWorker[],
  smokeDispatch = false,
): string {
  if (workers.length === 0) {
    return `export function startConfiguredApplicationWorkers(
  in catalog: ApplicationWorkerCatalog,
  services: Services,
  message: ApplicationWorkerMessageHandler
): ApplicationWorkers {
  return startEmptyApplicationWorkers();
}`;
  }

  for (const worker of workers) {
    if (worker.engine !== "zjs") {
      throw new Error(
        `[zapp] native Z application worker ${JSON.stringify(worker.id)} uses `
        + `engine ${JSON.stringify(worker.engine)}; the first native runtime tier supports "zjs"`,
      );
    }
    if (worker.bytecode) {
      throw new Error(
        `[zapp] native Z application worker ${JSON.stringify(worker.id)} requests bytecode; `
        + "source-module startup must land before the ZJS bytecode loader",
      );
    }
  }

  const lines: string[] = [];
  workers.forEach((worker, index) => {
    lines.push(
      `const applicationWorkerSource${index}: embed.StaticBytes = `
      + `embed.bytes(${JSON.stringify(zEmbeddedApplicationWorkerPath(worker, index))});`,
    );
  });
  lines.push(
    "",
    "export function startConfiguredApplicationWorkers(",
    "  in catalog: ApplicationWorkerCatalog,",
    "  services: Services,",
    "  message: ApplicationWorkerMessageHandler",
    "): ApplicationWorkers on thread.main {",
    "  let controls = Array<ApplicationWorkerControl>();",
  );
  workers.forEach((worker, index) => {
    lines.push(
      `  const control${index} = startZjsApplicationWorker(`,
      `    ${JSON.stringify(worker.id)},`,
      "    WorkerModule({",
      `      source: applicationWorkerSource${index},`,
      `      name: ${JSON.stringify(worker.moduleUrl)},`,
      "    }),",
      `    catalog.entries[${index}].serviceMethods,`,
      "    services,",
      "    message",
      "  );",
    );
    if (smokeDispatch) {
      lines.push(
        `  match (control${index}.dispatch("ping", "configured-worker-smoke")) {`,
        "    accepted => {}",
        `    _ => control${index}.requestCancellation();`,
        "  }",
      );
    }
    lines.push(`  controls.push(control${index});`);
  });
  lines.push(
    "  return new ApplicationWorkers({ controls: controls.freeze() });",
    "}",
  );
  return lines.join("\n");
}
