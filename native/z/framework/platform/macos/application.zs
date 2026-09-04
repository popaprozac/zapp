import { PreparedApplication } from "../../application-contract.zs";
import {
  ApplicationError,
  WindowError,
} from "../../application-error.zs";
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
import { macOSApplicationMenuBackend } from "./menu-backend.zs";
import {
  startConfiguredApplicationWorkers,
} from "../../configured-application.zs";
import {
  ApplicationWorkerAsyncServiceHandler,
  ApplicationWorkerDispatch,
  ApplicationWorkerMessageHandler,
  ApplicationWorkerServiceCancelHandler,
} from "../../worker/application-workers.zs";
import { ApplicationWorkerLifecycleHandler } from "../../worker/lifecycle.zs";
import { ApplicationWorkerSendOperation } from "../../worker/worker-manager.zs";

export async function runMacOSApplication(
  config: PreparedApplication,
  updates: TaskScope
): i32 throws ApplicationError on thread.main {
  const context = config.contextSnapshot();
  let windows = config.windows;
  let dialogs = config.dialogs;
  let clipboard = config.clipboard;
  let menu = config.menu;
  const registeredWindows = windows.all();
  if (registeredWindows.length == 0) {
    throw ApplicationError.window(WindowError({
      id: "",
      message: "a macOS desktop application requires a registered window in this tier",
    }));
  }
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
    menu
  );
  const workerManagerLifetime = installApplicationWorkerManager(
    workerManager
  );
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
  dialogs.start(macOSDialogBackend());
  clipboard.start(macOSClipboardBackend());
  const started = attempt config.lifecycles.start(in context);
  match (started) {
    success => {}
    failure(startError) => {
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
  const status = runMacOSApplicationLoop();
  events.finish();
  workers.requestCancellation();
  cancelAllMacOSApplicationWorkerServices();
  workers.join();
  workerManager.finish();
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
