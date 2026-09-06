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
import {
  createApplicationContext,
  runApplicationPlatform,
} from "../framework/platform.zs";
import {
  ApplicationContext as FrameworkApplicationContext,
  ApplicationPaths as FrameworkApplicationPaths,
} from "./zapp/service.zs";
import {
  ApplicationServices as FrameworkApplicationServices,
  ServiceRegistrationError as FrameworkServiceRegistrationError,
  createApplicationServices,
} from "../framework/application-services.zs";
import { thread } from "std/thread";
import { TaskScope } from "std/async";
import { Once } from "std/sync";
import {
  requireApplicationPublicationState,
} from "../framework/application-publication.zs";
import {
  WindowManager,
  createWindowManager,
} from "../framework/window.zs";
import {
  DialogManager,
  createDialogManager,
} from "../framework/dialog.zs";
import {
  ClipboardManager,
  createClipboardManager,
} from "../framework/clipboard.zs";
import {
  NotificationManager,
  createNotificationManager,
} from "../framework/notifications.zs";
import {
  ShellManager,
  createShellManager,
} from "../framework/shell.zs";
import {
  FileManager,
  createFileManager,
} from "../framework/files.zs";
import {
  FilesystemAuthority,
  createFilesystemAuthority,
} from "../framework/filesystem-authority.zs";
import {
  ApplicationMenu,
  createApplicationMenu,
} from "../framework/application-menu.zs";

export type ApplicationError = FrameworkApplicationError;
export type ApplicationState = FrameworkApplicationState;
export type ApplicationStateError = FrameworkApplicationStateError;
export type ApplicationMetadata = FrameworkApplicationMetadata;
export type ApplicationContext = FrameworkApplicationContext;
export type ApplicationPaths = FrameworkApplicationPaths;
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

// One stable application identity owns stable manager identities. The scalar
// main-affine marker routes final ARC release to the application's executor
// without making harmless metadata methods main-only.
export readonly class Application {
  readonly metadata: ApplicationMetadata;
  readonly context: ApplicationContext;
  readonly permissions: ApplicationPermissions;
  readonly capabilities: ApplicationCapabilities;
  readonly events: ApplicationEvents;
  readonly windows: WindowManager;
  readonly dialogs: DialogManager;
  readonly clipboard: ClipboardManager;
  readonly notifications: NotificationManager;
  readonly shell: ShellManager;
  readonly files: FileManager;
  readonly menu: ApplicationMenu;
  readonly workers: WorkerManager;
  readonly services: ApplicationServices;
  internal readonly filesystemAuthority: FilesystemAuthority;
  internal readonly runState: ApplicationRunState;
  internal readonly lifecycleMarker: i32 on thread.main;

  constructor() {
    const metadata = configuredApplicationMetadata();
    this.context = createApplicationContext(in metadata);
    this.metadata = move metadata;
    this.permissions = configuredApplicationPermissions();
    this.capabilities = configuredApplicationCapabilities();
    this.events = createApplicationEvents();
    this.windows = createWindowManager();
    this.clipboard = createClipboardManager();
    this.notifications = createNotificationManager();
    this.filesystemAuthority = createFilesystemAuthority(
      in this.context.paths
    );
    this.dialogs = createDialogManager(this.filesystemAuthority);
    this.shell = createShellManager(this.filesystemAuthority);
    this.files = createFileManager(this.filesystemAuthority);
    this.menu = createApplicationMenu();
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
    const publicationState = currentApplication.state();
    try requireApplicationPublicationState(publicationState);
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
  let contextArguments = Array<String>();
  let contextArgumentIndex: usize = 0;
  while (contextArgumentIndex < app.context.arguments.length) {
    const argumentLength: usize =
      app.context.arguments[contextArgumentIndex].byteLength;
    contextArguments.push(
      app.context.arguments[contextArgumentIndex].copyBytes(0, argumentLength)
    );
    contextArgumentIndex = contextArgumentIndex + 1;
  }
  const metadata = ApplicationMetadata({
    name: copy app.metadata.name,
    identifier: copy app.metadata.identifier,
    version: copy app.metadata.version,
  });
  const contextMetadata = ApplicationMetadata({
    name: copy app.context.metadata.name,
    identifier: copy app.context.metadata.identifier,
    version: copy app.context.metadata.version,
  });
  const paths = FrameworkApplicationPaths({
    executable: copy app.context.paths.executable,
    resources: copy app.context.paths.resources,
    data: copy app.context.paths.data,
    config: copy app.context.paths.config,
    cache: copy app.context.paths.cache,
  });
  const context = FrameworkApplicationContext({
    metadata: move contextMetadata,
    arguments: contextArguments.freeze(),
    paths: move paths,
  });
  const permissions = app.permissions;
  const capabilities = app.capabilities;
  const events = app.events;
  const windows = app.windows;
  const dialogs = app.dialogs;
  const clipboard = app.clipboard;
  const notifications = app.notifications;
  const filesystemAuthority = app.filesystemAuthority;
  const shell = app.shell;
  const files = app.files;
  const menu = app.menu;
  const workers = app.workers;
  const services = app.services;
  const { routes, asynchronous, lifecycles } = services.prepare();
  return new PreparedApplication({
    metadata: move metadata,
    context: move context,
    permissions,
    capabilities,
    events,
    windows,
    dialogs,
    clipboard,
    notifications,
    filesystemAuthority,
    shell,
    files,
    menu,
    services: new AsyncServices({
      synchronous: routes,
      asynchronous,
    }),
    lifecycles,
    workers,
  });
}
