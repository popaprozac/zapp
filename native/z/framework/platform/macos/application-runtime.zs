import { ApplicationPermissions } from "../../application-permissions.zs";
import {
  ApplicationCapabilities,
} from "../../application-capabilities.zs";
import { AsyncServices } from "../../async-services.zs";
import { ApplicationMenu } from "../../application-menu.zs";
import { ContextMenuSessions, createContextMenuSessions } from "../../context-menu.zs";
import { ClipboardManager } from "../../clipboard.zs";
import { NotificationManager } from "../../notifications.zs";
import { ShellManager } from "../../shell.zs";
import { FileManager } from "../../files.zs";
import { bridgeFailure } from "../../bridge.zs";
import { createRelatedDocuments } from "../../related-documents.zs";
import { RelatedWindowCreations } from "../../related-window-creations.zs";
import { MacOSRelatedWindows } from "./related-window-creations.zs";
import { MacOSWindowRegistry } from "./window-registry.zs";
import { WindowStateStore } from "../../window-state.zs";
import { MacOSWindowRuntime } from "./window-runtime.zs";
import { NativeWindowClosedOperation } from "./window-delegate.zs";
import { Map } from "std/collections";
import { Once, OnceLifetime } from "std/sync";
import { TaskControl, TaskScope } from "std/async";
import { thread } from "std/thread";
import {
  WindowManager,
} from "../../window.zs";
import { stopMacOSRunLoop } from "./application-host.zs";
import {
  DesktopRouteMessageOperation,
} from "./document-transport.zs";
import {
  deliverApplicationWorkerLifecycle,
  deliverApplicationWorkerMessage,
} from "../../worker/manager-runtime.zs";
import {
  ApplicationWorkers,
  ApplicationWorkerDispatch,
  applicationWorkerServiceResponse,
  attachApplicationWorkerServiceRequest,
  beginApplicationWorkerServiceRequest,
  cancelAllApplicationWorkerServiceRequests,
  cancelApplicationWorkerServiceRequest,
  completeApplicationWorkerService,
  createApplicationWorkerServiceRequests,
  emptyApplicationWorkers,
  finishApplicationWorkerServiceRequest,
} from "../../worker/application-workers.zs";

type BeginWorkerServiceRequest = (
  requestId: u64
) => u64 on thread.any;

type AttachWorkerServiceRequest = (
  requestId: u64,
  control: TaskControl
) => void on thread.any;

type FinishWorkerServiceRequest = (
  requestId: u64,
  generation: u64
) => void on thread.any;

type CancelWorkerServiceRequest = (
  requestId: u64
) => boolean on thread.any;

type CancelAllWorkerServiceRequests = () => void on thread.any;

internal class MacOSApplicationRuntime {
  readonly permissions: ApplicationPermissions;
  readonly services: AsyncServices;
  readonly updates: TaskScope;
  readonly windowManager: WindowManager on thread.main;
  readonly clipboard: ClipboardManager on thread.main;
  readonly notifications: NotificationManager on thread.main;
  readonly shell: ShellManager on thread.main;
  readonly files: FileManager on thread.main;
  readonly menu: ApplicationMenu on thread.main;
  readonly contextMenus: ContextMenuSessions on thread.main;
  applicationWorkers: ApplicationWorkers on thread.main;
  readonly beginWorkerServiceRequest: BeginWorkerServiceRequest;
  readonly attachWorkerServiceRequest: AttachWorkerServiceRequest;
  readonly finishWorkerServiceRequest: FinishWorkerServiceRequest;
  readonly cancelWorkerServiceRequest: CancelWorkerServiceRequest;
  readonly cancelAllWorkerServiceRequests: CancelAllWorkerServiceRequests;
  readonly windows: MacOSWindowRegistry on thread.main;

  function installApplicationWorkers(
    inout this,
    workers: ApplicationWorkers
  ): void on thread.main {
    this.applicationWorkers = move workers;
  }

  function dispatchApplicationWorker(
    in workerId: String,
    in channel: String,
    in payload: String
  ): ApplicationWorkerDispatch on thread.main {
    return this.applicationWorkers.dispatch(
      in workerId,
      in channel,
      in payload
    );
  }
}

const application = Once<MacOSApplicationRuntime>();

function recordClosedNativeWindow(
  nativeId: i32
): void on thread.main {
  const current = application.get();
  current.windows.nativeWindowClosed(nativeId);
}

internal function currentMacOSApplication(): MacOSApplicationRuntime {
  return application.get();
}

internal function abortMacOSApplicationRuntime(): void on thread.main {
  const current = application.get();
  current.windows.closeAllNativeWindows();
  current.windows.stateStore.stop();
}

internal function requestMacOSApplicationQuit(): void on thread.main {
  const current = application.get();
  current.windows.closeAllNativeWindows();
  stopMacOSRunLoop();
}

internal function publishMacOSApplicationQuitRequested(
  cancelled: boolean
): void on thread.main {
  const current = application.get();
  current.windows.deliverQuitRequested(cancelled);
}

internal function installMacOSApplicationWorkers(
  workers: ApplicationWorkers
): void on thread.main {
  const current = application.get();
  current.installApplicationWorkers(move workers);
}

function deliverApplicationWorkerMessageOnMain(
  workerId: String,
  channel: String,
  payload: String
): void on thread.main {
  deliverApplicationWorkerMessage(
    copy workerId,
    copy channel,
    copy payload
  );
  const current = application.get();
  current.windows.deliverApplicationWorkerMessage(
    in workerId,
    in channel,
    in payload
  );
}

internal function publishMacOSApplicationWorkerMessage(
  workerId: String,
  channel: String,
  payload: String
): void on thread.any {
  const current = application.get();
  const updates = current.updates;
  const scheduled = updates.schedule(
    thread.main,
    async move (): void => deliverApplicationWorkerMessageOnMain(
      move workerId,
      move channel,
      move payload
    )
  );
  if (!scheduled.accepted) return;
}

internal function publishMacOSApplicationWorkerLifecycle(
  workerId: String,
  phase: i32,
  incarnation: u64,
  retry: u64,
  maxRetries: u64,
  withinMilliseconds: u64,
  message: String
): void on thread.any {
  const current = application.get();
  const updates = current.updates;
  const scheduled = updates.schedule(
    thread.main,
    async move (): void => deliverApplicationWorkerLifecycle(
      move workerId,
      phase,
      incarnation,
      retry,
      maxRetries,
      withinMilliseconds,
      move message
    )
  );
  if (!scheduled.accepted) return;
}

async function finishMacOSApplicationWorkerService(
  workerIdentity: usize,
  requestId: u64,
  generation: u64,
  method: String,
  arguments: String
): void on thread.main {
  const current = application.get();
  const invoked = await current.services.invoke(
    move method,
    move arguments
  );
  const response = applicationWorkerServiceResponse(move invoked);
  markMacOSApplicationWorkerServiceFinished(requestId, generation);
  completeApplicationWorkerService(
    workerIdentity,
    requestId,
    in response
  );
}

function markMacOSApplicationWorkerServiceFinished(
  requestId: u64,
  generation: u64
): void on thread.main {
  const current = application.get();
  current.finishWorkerServiceRequest(requestId, generation);
}

internal function publishMacOSApplicationWorkerService(
  workerIdentity: usize,
  workerId: String,
  requestId: u64,
  method: String,
  arguments: String
): void on thread.any {
  const current = application.get();
  const updates = current.updates;
  const generation = current.beginWorkerServiceRequest(requestId);
  const control = updates.schedule(
    thread.main,
    async move (): void => await finishMacOSApplicationWorkerService(
      workerIdentity,
      requestId,
      generation,
      move method,
      move arguments
    )
  );
  current.attachWorkerServiceRequest(requestId, control);
  if (!control.accepted) {
    current.cancelWorkerServiceRequest(requestId);
    const closing = bridgeFailure(
      0,
      "APPLICATION_CLOSING",
      `Application is closing; worker ${workerId} service was not started`
    );
    completeApplicationWorkerService(
      workerIdentity,
      requestId,
      in closing
    );
    return;
  }
}

internal function cancelMacOSApplicationWorkerService(
  requestId: u64
): void on thread.any {
  const current = application.get();
  current.cancelWorkerServiceRequest(requestId);
}

internal function cancelAllMacOSApplicationWorkerServices(): void on thread.main {
  const current = application.get();
  current.cancelAllWorkerServiceRequests();
}

internal function initializeMacOSApplicationRuntimeState(
  name: String,
  permissions: ApplicationPermissions,
  capabilities: ApplicationCapabilities,
  services: AsyncServices,
  updates: TaskScope,
  windowManager: WindowManager,
  clipboard: ClipboardManager,
  notifications: NotificationManager,
  shell: ShellManager,
  files: FileManager,
  menu: ApplicationMenu,
  routeMessage: DesktopRouteMessageOperation,
  stateStore: WindowStateStore
): OnceLifetime<MacOSApplicationRuntime> on thread.main {
  const requests = createApplicationWorkerServiceRequests();
  const beginWorkerServiceRequest: BeginWorkerServiceRequest = move (
    requestId: u64
  ): u64 => beginApplicationWorkerServiceRequest(in requests, requestId);
  const attachWorkerServiceRequest: AttachWorkerServiceRequest = move (
    requestId: u64,
    control: TaskControl
  ): void => attachApplicationWorkerServiceRequest(
    in requests,
    requestId,
    control
  );
  const finishWorkerServiceRequest: FinishWorkerServiceRequest = move (
    requestId: u64,
    generation: u64
  ): void => finishApplicationWorkerServiceRequest(
    in requests,
    requestId,
    generation
  );
  const cancelWorkerServiceRequest: CancelWorkerServiceRequest = move (
    requestId: u64
  ): boolean => cancelApplicationWorkerServiceRequest(in requests, requestId);
  const cancelAllWorkerServiceRequests: CancelAllWorkerServiceRequests = move (
  ): void => cancelAllApplicationWorkerServiceRequests(in requests);
  const contextMenus = createContextMenuSessions();
  const didCloseNativeWindow: NativeWindowClosedOperation = recordClosedNativeWindow;
  const documents = createRelatedDocuments();
  const creations = new RelatedWindowCreations(documents);
  const windows = new MacOSWindowRegistry({
    filesystem: files.authority,
    name: move name,
    stateStore,
    capabilities,
    windowManager,
    menu,
    contextMenus,
    routeMessage,
    didCloseNativeWindow,
    nativeWindows: Map<i32, MacOSWindowRuntime>(),
    retiredNativeWindows: Array<MacOSWindowRuntime>(),
    nextNativeWindowId: 1,
    documents,
    creations,
    related: new MacOSRelatedWindows(documents, creations, routeMessage, weak windowManager, didCloseNativeWindow),
  });
  const value = new MacOSApplicationRuntime({
    permissions,
    services: move services,
    updates,
    windowManager,
    clipboard,
    notifications,
    shell,
    files,
    menu,
    applicationWorkers: emptyApplicationWorkers(),
    beginWorkerServiceRequest,
    attachWorkerServiceRequest,
    finishWorkerServiceRequest,
    cancelWorkerServiceRequest,
    cancelAllWorkerServiceRequests,
    contextMenus,
    windows,
  });
  return application.initialize(move value);
}
