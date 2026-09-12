import { PreparedApplication } from "../../application-contract.zs";
import { TrayManagerLifetime } from "../../tray.zs";
import { macOSTrayBackend } from "./tray-backend.zs";
import {
  ApplicationError,
  PlatformError,
  WindowError,
} from "../../application-error.zs";
import { ApplicationEvents } from "../../application-events.zs";
import { Channel } from "std/channel";
import { MacOSLaunchReadiness, listenMacOSApplicationLaunches, releaseMacOSLaunchSender } from "./launch-listener.zs";
import { initializeMacOSLaunchDelivery } from "./launch-delivery.zs";
import { MacOSLaunchTransportError } from "./instance-transport.zs";
import { MacOSLaunchCancellation } from "./launch-cancellation.zs";
import { ApplicationQuitOperation } from "../../application-events.zs";
import { TaskScope } from "std/async";
import { thread } from "std/thread";
import {
  abortMacOSApplicationRuntime,
  cancelAllMacOSApplicationWorkerServices,
  cancelMacOSApplicationWorkerService,
  installMacOSApplicationWorkers,
  publishMacOSApplicationWorkerLifecycle,
  publishMacOSApplicationWorkerMessage,
  publishMacOSApplicationWorkerService,
  publishMacOSApplicationQuitRequested,
  requestMacOSApplicationQuit,
} from "./application-runtime.zs";
import {
  installApplicationWorkerManager,
} from "../../worker/manager-runtime.zs";
import { initializeMacOSApplicationRuntime } from "./runtime.zs";
import {
  initializeMacOSApplicationHost,
  runMacOSApplicationLoop,
} from "./application-host.zs";
import { macOSWindowBackend } from "./window-backend.zs";
import { macOSDialogBackend } from "./dialog-backend.zs";
import { macOSClipboardBackend } from "./clipboard-backend.zs";
import { macOSNotificationBackend } from "./notifications-backend.zs";
import { macOSShellBackend } from "./shell-backend.zs";
import {
  macOSFilesystemAuthorityBackend,
} from "./filesystem-authority-backend.zs";
import { macOSApplicationMenuBackend } from "./menu-backend.zs";
import {
  startConfiguredApplicationWorkers,
  configuredApplicationDeepLinkSchemes,
  configuredApplicationSingleInstance,
} from "../../configured-application.zs";
import {
  ApplicationWorkerAsyncServiceHandler,
  ApplicationWorkerDispatch,
  ApplicationWorkerMessageHandler,
  ApplicationWorkerServiceCancelHandler,
} from "../../worker/application-workers.zs";
import { ApplicationWorkerLifecycleHandler } from "../../worker/lifecycle.zs";
import { ApplicationWorkerSendOperation } from "../../worker/worker-manager.zs";

function applicationLaunchFailure(error: MacOSLaunchTransportError): ApplicationError {
  const { code, message, mayHaveBeenAdmitted } = move error;
  const description = mayHaveBeenAdmitted
    ? `${message}; the primary may have accepted this launch; it was not replayed`
    : move message;
  return ApplicationError.platform(PlatformError({ code, message: description }));
}

export async function runMacOSApplication(
  config: PreparedApplication,
  updates: TaskScope
): i32 throws ApplicationError on thread.main {
  if (!configuredApplicationSingleInstance()) {
    return try await runMacOSPrimaryApplication(config, updates);
  }
  const inbox = config.events.activationInbox();
  const deliveryLifetime = initializeMacOSLaunchDelivery(config.events);
  const launchUpdates = new TaskScope();
  const { sender, receiver } = Channel<MacOSLaunchReadiness>.bounded(1);
  const readiness = receiver.sync();
  const cancellation = match (attempt MacOSLaunchCancellation.create()) {
    success(value) => value;
    failure(code) => throw ApplicationError.platform(PlatformError({ code, message: "launch cancellation setup failed" }));
  };
  const identifier = copy config.metadata.identifier;
  const listener = thread.spawn(async move (): i32 => await listenMacOSApplicationLaunches(move identifier, inbox, launchUpdates, sender, cancellation));
  releaseMacOSLaunchSender(move sender);
  const startup = readiness.receive();
  // Keep the outcome owned until both the listener and every admitted main
  // wake have joined. A setup error must follow the same shutdown path.
  const outcome = attempt await runMacOSReadyApplication(move startup, config, updates);
  config.events.finish();
  inbox.close();
  cancellation.request();
  await listener.cancel();
  await launchUpdates.cancel();
  await updates.cancel();
  return match (outcome) { success(status) => status; failure(error) => throw error; };
}

async function runMacOSReadyApplication(
  startup: Option<MacOSLaunchReadiness>, config: PreparedApplication,
  updates: TaskScope
): i32 throws ApplicationError on thread.main {
  return match (startup) {
    some(state) => match (state) {
      primary => try await runMacOSPrimaryApplication(config, updates);
      forwarded => 0;
      failure(error) => throw applicationLaunchFailure(move error);
    }
    none => throw ApplicationError.platform(PlatformError({
      code: 0, message: "launch listener ended before reporting readiness",
    }));
  };
}

// Close callback admission on every exit before the native runtime/host is
// released. A queued transport wake then only observes a closed inbox; its
// separate delivery owner remains alive until the outer listener join.
struct MacOSActivationLifetime on thread.main {
  events: ApplicationEvents;
  deinit { this.events.finish(); }
}

async function runMacOSPrimaryApplication(
  config: PreparedApplication,
  updates: TaskScope
): i32 throws ApplicationError on thread.main {
  const context = config.contextSnapshot();
  let windows = config.windows;
  let dialogs = config.dialogs;
  let clipboard = config.clipboard;
  let notifications = config.notifications;
  let filesystemAuthority = config.filesystemAuthority;
  let shell = config.shell;
  const files = config.files;
  let menu = config.menu;
  const trays = config.trays;
  const trayLifetime = TrayManagerLifetime({ manager: trays });
  config.events.configureActivation(configuredApplicationDeepLinkSchemes());
  const hostLifetime = initializeMacOSApplicationHost(config.events);
  let workerManager = config.workers;
  const lifetime = initializeMacOSApplicationRuntime(
    copy config.metadata.name,
    config.permissions,
    config.capabilities,
    config.services,
    updates,
    windows,
    clipboard,
    notifications,
    shell,
    files,
    menu
  );
  const workerManagerLifetime = installApplicationWorkerManager(
    workerManager
  );
  const activationLifetime = MacOSActivationLifetime({ events: config.events });
  const realized = attempt windows.start(macOSWindowBackend(), true);
  match (realized) {
    success => {}
    failure(windowError) => {
      windows.stop();
      abortMacOSApplicationRuntime();
      throw ApplicationError.window(windowError);
    }
  }
  const menuStarted = attempt menu.start(macOSApplicationMenuBackend());
  match (menuStarted) {
    success => {}
    failure(menuError) => {
      windows.stop();
      abortMacOSApplicationRuntime();
      throw ApplicationError.menu(menuError);
    }
  }
  match (attempt trays.start(macOSTrayBackend())) {
    success => {}
    failure(trayError) => {
      menu.stop();
      windows.stop();
      abortMacOSApplicationRuntime();
      throw ApplicationError.tray(move trayError);
    }
  }
  dialogs.start(macOSDialogBackend());
  clipboard.start(macOSClipboardBackend());
  notifications.start(macOSNotificationBackend());
  filesystemAuthority.start(macOSFilesystemAuthorityBackend());
  shell.start(macOSShellBackend());
  const started = attempt config.lifecycles.start(in context);
  match (started) {
    success => {}
    failure(startError) => {
      shell.stop();
      filesystemAuthority.stop();
      notifications.stop();
      clipboard.stop();
      dialogs.stop();
      menu.stop();
      windows.stop();
      abortMacOSApplicationRuntime();
      throw ApplicationError.lifecycle(startError);
    }
  }
  const workerMessages: ApplicationWorkerMessageHandler =
    publishMacOSApplicationWorkerMessage;
  const workerServices: ApplicationWorkerAsyncServiceHandler =
    publishMacOSApplicationWorkerService;
  const cancelWorkerService: ApplicationWorkerServiceCancelHandler =
    cancelMacOSApplicationWorkerService;
  const workerLifecycle: ApplicationWorkerLifecycleHandler =
    publishMacOSApplicationWorkerLifecycle;
  const workers = startConfiguredApplicationWorkers(
    workerManager.catalog,
    config.services.synchronous,
    workerServices,
    cancelWorkerService,
    workerMessages,
    workerLifecycle
  );
  const dispatchWorkers = workers;
  const sendWorker: ApplicationWorkerSendOperation = move (
    in workerId: String,
    in channel: String,
    in payload: String
  ): ApplicationWorkerDispatch => dispatchWorkers.dispatch(
    in workerId,
    in channel,
    in payload
  );
  workerManager.install(sendWorker);
  installMacOSApplicationWorkers(workers);
  let events = config.events;
  const quitApplication: ApplicationQuitOperation = move (
  ): void => requestMacOSApplicationQuit();
  events.start(quitApplication);
  events.observeQuit(publishMacOSApplicationQuitRequested);
  events.startActivation();
  const status = runMacOSApplicationLoop();
  events.finish();
  trays.stop();
  workers.requestCancellation();
  cancelAllMacOSApplicationWorkerServices();
  workers.join();
  workerManager.finish();
  shell.stop();
  filesystemAuthority.stop();
  notifications.stop();
  clipboard.stop();
  dialogs.stop();
  menu.stop();
  windows.stop();
  await updates.cancel();
  const stopped = attempt config.lifecycles.stop(in context);
  match (stopped) {
    success => {}
    failure(stopError) => throw ApplicationError.lifecycle(stopError);
  }
  return status;
}
