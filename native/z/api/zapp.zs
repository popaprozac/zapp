import { PreparedApplication } from "../framework/application-contract.zs";
import {
  ApplicationError as FrameworkApplicationError,
  ApplicationState as FrameworkApplicationState,
  ApplicationStateError as FrameworkApplicationStateError,
} from "../framework/application-error.zs";
import {
  ApplicationMetadata as FrameworkApplicationMetadata,
} from "../framework/application-metadata.zs";
import { ApplicationPermissions } from "../framework/application-permissions.zs";
import { ApplicationCapabilities } from "../framework/application-capabilities.zs";
import { AsyncServices } from "../framework/async-services.zs";
import {
  configuredApplicationMetadata,
  configuredApplicationPermissions,
  configuredApplicationCapabilities,
  configuredApplicationWorkers,
} from "../framework/configured-application.zs";
import {
  WorkerManager,
  createWorkerManager,
} from "../framework/worker/worker-manager.zs";
import { runApplicationPlatform } from "../framework/platform.zs";
import {
  ApplicationServices as FrameworkApplicationServices,
  ServiceRegistrationError as FrameworkServiceRegistrationError,
  createApplicationServices,
} from "../framework/application-services.zs";
import { thread } from "std/thread";
import { TaskScope } from "std/async";
import { Once } from "std/sync";
import {
  WindowManager,
  createWindowManager,
} from "../framework/window.zs";

export type ApplicationError = FrameworkApplicationError;
export type ApplicationState = FrameworkApplicationState;
export type ApplicationStateError = FrameworkApplicationStateError;
export type ApplicationMetadata = FrameworkApplicationMetadata;
export type ApplicationServices = FrameworkApplicationServices;
export type ServiceRegistrationError = FrameworkServiceRegistrationError;

class ApplicationRunState on thread.main {
  value: ApplicationState;

  function begin(inout this): boolean {
    match (this.value) {
      configuring => {
        this.value = FrameworkApplicationState.running;
        return true;
      }
      _ => return false;
    }
  }

  function error(): ApplicationStateError {
    return match (this.value) {
      configuring => FrameworkApplicationStateError({
        state: FrameworkApplicationState.configuring,
        message: "Application.run() has not started",
      });
      running => FrameworkApplicationStateError({
        state: FrameworkApplicationState.running,
        message: "Application.run() is already active",
      });
      stopped => FrameworkApplicationStateError({
        state: FrameworkApplicationState.stopped,
        message: "Application.run() cannot restart after shutdown",
      });
    };
  }

  function finish(inout this): void {
    this.value = FrameworkApplicationState.stopped;
  }
}

struct ApplicationRunLifetime on thread.main {
  runState: ApplicationRunState;

  deinit {
    let runState = this.runState;
    runState.finish();
  }
}

// One stable application identity owns stable manager identities. The scalar
// main-affine marker routes final ARC release to the application's executor
// without making harmless metadata methods main-only.
export readonly class Application {
  readonly metadata: ApplicationMetadata;
  readonly permissions: ApplicationPermissions;
  readonly capabilities: ApplicationCapabilities;
  readonly windows: WindowManager;
  readonly workers: WorkerManager;
  readonly services: ApplicationServices;
  internal readonly runState: ApplicationRunState;
  internal readonly lifecycleMarker: i32 on thread.main;

  constructor() {
    this.metadata = configuredApplicationMetadata();
    this.permissions = configuredApplicationPermissions();
    this.capabilities = configuredApplicationCapabilities();
    this.windows = createWindowManager();
    this.workers = createWorkerManager(configuredApplicationWorkers());
    this.services = createApplicationServices();
    this.runState = new ApplicationRunState({
      value: FrameworkApplicationState.configuring,
    });
    this.lifecycleMarker = 1;
  }

  static function current(): Application {
    return currentApplication.get();
  }

  function state(): ApplicationState on thread.main {
    return this.runState.value;
  }

  async function run(): i32 throws ApplicationError on thread.main {
    let applicationState = this.runState;
    if (!applicationState.begin()) {
      throw FrameworkApplicationError.state(applicationState.error());
    }
    const sourceApplication = this;
    const config = prepareApplication(in sourceApplication);
    const publishedApplication = this;
    const lifetime = currentApplication.initialize(move publishedApplication);
    const runLifetime = ApplicationRunLifetime({
      runState: applicationState,
    });
    const updates = new TaskScope();
    return try await runApplicationPlatform(config, updates);
  }
}

const currentApplication = Once<Application>();

function prepareApplication(
  in app: Application
): PreparedApplication on thread.main {
  const metadata = ApplicationMetadata({
    name: copy app.metadata.name,
    identifier: copy app.metadata.identifier,
    version: copy app.metadata.version,
  });
  const permissions = app.permissions;
  const capabilities = app.capabilities;
  const windows = app.windows;
  const workers = app.workers;
  const services = app.services;
  const { routes, asynchronous, lifecycles } = services.prepare();
  return new PreparedApplication({
    metadata: move metadata,
    permissions,
    capabilities,
    windows,
    services: new AsyncServices({
      synchronous: routes,
      asynchronous,
    }),
    lifecycles,
    workers,
  });
}
