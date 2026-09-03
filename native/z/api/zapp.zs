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
import {
  ApplicationEvents as FrameworkApplicationEvents,
  ApplicationEventSubscription as FrameworkApplicationEventSubscription,
  ApplicationEventSubscriptionError as FrameworkApplicationEventSubscriptionError,
  ApplicationQuitRequestedEvent as FrameworkApplicationQuitRequestedEvent,
  createApplicationEvents,
} from "../framework/application-events.zs";
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
import { Once, OnceState } from "std/sync";
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
export type ApplicationEvents = FrameworkApplicationEvents;
export type ApplicationEventSubscription = FrameworkApplicationEventSubscription;
export type ApplicationEventSubscriptionError = FrameworkApplicationEventSubscriptionError;
export type ApplicationQuitRequestedEvent = FrameworkApplicationQuitRequestedEvent;

class ApplicationRunState on thread.main {
  value: ApplicationState;

  function begin(inout this): boolean {
    const current = this.value;
    match (current) {
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
  events: ApplicationEvents;

  deinit {
    let runState = this.runState;
    runState.finish();
    let events = this.events;
    events.finish();
  }
}

function requireApplicationPublication(): void throws ApplicationError on thread.main {
  match (currentApplication.state()) {
    empty => {}
    initialized => throw FrameworkApplicationError.state(
      FrameworkApplicationStateError({
        state: FrameworkApplicationState.running,
        message: "Another Application.run() is already active in this process",
      })
    );
    closed => throw FrameworkApplicationError.state(
      FrameworkApplicationStateError({
        state: FrameworkApplicationState.stopped,
        message: "Application.run() cannot publish a new application after process shutdown",
      })
    );
  }
}

// One stable application identity owns stable manager identities. The scalar
// main-affine marker routes final ARC release to the application's executor
// without making harmless metadata methods main-only.
export readonly class Application {
  readonly metadata: ApplicationMetadata;
  readonly permissions: ApplicationPermissions;
  readonly capabilities: ApplicationCapabilities;
  readonly events: ApplicationEvents;
  readonly windows: WindowManager;
  readonly workers: WorkerManager;
  readonly services: ApplicationServices;
  internal readonly runState: ApplicationRunState;
  internal readonly lifecycleMarker: i32 on thread.main;

  constructor() {
    this.metadata = configuredApplicationMetadata();
    this.permissions = configuredApplicationPermissions();
    this.capabilities = configuredApplicationCapabilities();
    this.events = createApplicationEvents();
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

  function quit(): void on thread.main {
    this.events.requestQuit();
  }

  async function run(): i32 throws ApplicationError on thread.main {
    let applicationState = this.runState;
    if (!applicationState.begin()) {
      throw FrameworkApplicationError.state(applicationState.error());
    }
    const runLifetime = ApplicationRunLifetime({
      runState: applicationState,
      events: this.events,
    });
    try requireApplicationPublication();
    const sourceApplication = this;
    const config = prepareApplication(in sourceApplication);
    const publishedApplication = this;
    const lifetime = currentApplication.initialize(move publishedApplication);
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
  const events = app.events;
  const windows = app.windows;
  const workers = app.workers;
  const services = app.services;
  const { routes, asynchronous, lifecycles } = services.prepare();
  return new PreparedApplication({
    metadata: move metadata,
    permissions,
    capabilities,
    events,
    windows,
    services: new AsyncServices({
      synchronous: routes,
      asynchronous,
    }),
    lifecycles,
    workers,
  });
}
