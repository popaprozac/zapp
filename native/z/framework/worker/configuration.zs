export enum ApplicationWorkerEngine {
  zjs,
  bareJsc,
  bareV8,
  bareQuickJs,
  bareMicroQuickJs,
  bareHermes,
}

export readonly struct ApplicationWorkerRestartPolicy {
  enabled: boolean;
  maxRetries: usize;
  withinMilliseconds: u64;
}

// Build-resolved application worker. Source identifies the authored build
// input; moduleUrl identifies the packaged artifact consumed by the runtime.
// Permissions and service methods are already expanded from trusted capability
// profiles, so runtime JavaScript cannot request additional native authority.
export readonly struct ConfiguredApplicationWorker {
  id: String;
  source: String;
  moduleUrl: String;
  name: String;
  engine: ApplicationWorkerEngine;
  bytecode: boolean;
  restart: ApplicationWorkerRestartPolicy;
  capabilities: readonly Array<String>;
  permissions: readonly Array<String>;
  serviceMethods: readonly Array<String>;
}

export readonly struct ApplicationWorkerCatalog {
  entries: readonly Array<ConfiguredApplicationWorker>;
}

export function emptyApplicationWorkerCatalog(): ApplicationWorkerCatalog {
  let entries = Array<ConfiguredApplicationWorker>();
  return ApplicationWorkerCatalog({ entries: entries.freeze() });
}
