import WebKit from "WebKit/WebKit.h";
import { WindowError } from "../../application-error.zs";
import { ApplicationPermissions } from "../../application-permissions.zs";
import {
  ApplicationCapabilities,
  CapabilitySelection,
} from "../../application-capabilities.zs";
import { AsyncServices } from "../../async-services.zs";
import { BridgeResponse, bridgeFailure } from "../../bridge.zs";
import { Once, OnceLifetime } from "std/sync";
import { TaskControl, TaskScope } from "std/async";
import { Map } from "std/collections";
import { thread } from "std/thread";
import {
  WindowManager,
  WindowOptions,
} from "../../window.zs";
import { stopMacOSRunLoop } from "./application-host.zs";
import {
  DesktopDeliverResponseOperation,
  DesktopRouteMessageOperation,
} from "./message-handler.zs";
import { createMacOSWindowRuntime } from "./window-construction.zs";
import { MacOSWindowRuntime } from "./window-runtime.zs";
import {
  deliverWebViewApplicationWorkerMessage,
  deliverWebViewResponse,
} from "./response-delivery.zs";
import { webViewInjectionProfileExists } from "./webview-injections.zs";
import { NativeWindowClosedOperation } from "./window-delegate.zs";
import {
  deliverMacOSApplicationWorkerLifecycle,
} from "./worker-lifecycle.zs";
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
  readonly name: String;
  readonly permissions: ApplicationPermissions;
  readonly capabilities: ApplicationCapabilities;
  readonly services: AsyncServices;
  readonly updates: TaskScope;
  readonly windowManager: WindowManager on thread.main;
  readonly routeMessage: DesktopRouteMessageOperation on thread.main;
  readonly deliverMessageResponse: DesktopDeliverResponseOperation on thread.main;
  applicationWorkers: ApplicationWorkers on thread.main;
  readonly beginWorkerServiceRequest: BeginWorkerServiceRequest;
  readonly attachWorkerServiceRequest: AttachWorkerServiceRequest;
  readonly finishWorkerServiceRequest: FinishWorkerServiceRequest;
  readonly cancelWorkerServiceRequest: CancelWorkerServiceRequest;
  readonly cancelAllWorkerServiceRequests: CancelAllWorkerServiceRequests;
  nativeWindows: Map<i32, MacOSWindowRuntime> on thread.main;
  retiredNativeWindows: Array<MacOSWindowRuntime> on thread.main;
  nextNativeWindowId: i32 on thread.main;

  function createWindow(
    inout this,
    in id: String,
    in options: WindowOptions
  ): void throws WindowError on thread.main {
    for (const profile of options.capabilities) {
      if (!this.capabilities.hasProfile(profile)) {
        throw WindowError({
          id: copy id,
          message: `unknown window capability profile "${profile}"`,
        });
      }
    }
    const selected = this.capabilities.resolveProfiles(in options.capabilities);
    match (selected) {
      some(selection) => {
        try this.createResolvedWindow(in id, in options, selection);
        return;
      }
      none => throw WindowError({
        id: copy id,
        message: "could not resolve window capability profiles",
      });
    }
  }

  function createResolvedWindow(
    inout this,
    in id: String,
    in options: WindowOptions,
    selectedCapabilities: CapabilitySelection
  ): void throws WindowError on thread.main {
    for (const profile of options.inject) {
      if (!webViewInjectionProfileExists(profile)) {
        throw WindowError({
          id: copy id,
          message: `unknown webview inject profile "${profile}"`,
        });
      }
    }
    const nativeId = this.nextNativeWindowId;
    this.nextNativeWindowId = this.nextNativeWindowId + 1;
    const windowManager = this.windowManager;
    const windowManagerOwner = weak windowManager;
    const didClose: NativeWindowClosedOperation = recordClosedNativeWindow;
    const runtime = try createMacOSWindowRuntime(
      copy this.name,
      in id,
      nativeId,
      in options,
      selectedCapabilities,
      windowManagerOwner,
      this.routeMessage,
      this.deliverMessageResponse,
      didClose
    );
    this.nativeWindows.set(nativeId, runtime);
  }

  function nativeWindowClosed(
    inout this,
    nativeId: i32
  ): void on thread.main {
    const found = this.nativeWindows.remove(nativeId);
    match (found) {
      some(value) => {
        let window = value;
        window.pendingRequests.cancelAll();
        this.retiredNativeWindows.push(move window);
        if (this.nativeWindows.length == 0) {
          stopMacOSRunLoop();
        }
      }
      none => {}
    }
  }

  function closeAllNativeWindows(inout this): void on thread.main {
    // Teardown is already committed, so it bypasses cancellable user close
    // requests. Snapshot the native windows first because close callbacks
    // synchronously remove entries from the live registry.
    let windows = Array<MacOSWindowRuntime>();
    for (const entry of this.nativeWindows) {
      let window = entry.value;
      windows.push(move window);
    }
    for (const window of windows) {
      window.window.close();
    }
  }

  function beginRequest(
    inout this,
    windowId: i32,
    id: u64
  ): u64 on thread.main {
    const found = this.nativeWindows.remove(windowId);
    return match (found) {
      some(value) => {
        let window = value;
        const generation = window.pendingRequests.begin(id);
        this.nativeWindows.set(windowId, window);
        select generation;
      }
      none => 0;
    };
  }

  function attachRequest(
    inout this,
    windowId: i32,
    id: u64,
    control: TaskControl
  ): void on thread.main {
    const found = this.nativeWindows.remove(windowId);
    match (found) {
      some(value) => {
        let window = value;
        window.pendingRequests.attach(id, control);
        this.nativeWindows.set(windowId, window);
      }
      none => {}
    }
  }

  function finishRequest(
    inout this,
    windowId: i32,
    id: u64,
    generation: u64
  ): void on thread.main {
    const found = this.nativeWindows.remove(windowId);
    match (found) {
      some(value) => {
        let window = value;
        window.pendingRequests.finish(id, generation);
        this.nativeWindows.set(windowId, window);
      }
      none => {}
    }
  }

  function cancelRequest(
    inout this,
    windowId: i32,
    id: u64
  ): boolean on thread.main {
    const found = this.nativeWindows.remove(windowId);
    return match (found) {
      some(value) => {
        let window = value;
        const cancelled = window.pendingRequests.cancel(id);
        this.nativeWindows.set(windowId, window);
        select cancelled;
      }
      none => false;
    };
  }

  function showWindow(in id: String): void on thread.main {
    for (const entry of this.nativeWindows) {
      if (entry.value.id == id) {
        entry.value.window.makeKeyAndOrderFront(null);
        return;
      }
    }
  }

  function hideWindow(in id: String): void on thread.main {
    for (const entry of this.nativeWindows) {
      if (entry.value.id == id) {
        entry.value.window.orderOut(null);
        return;
      }
    }
  }

  function requestWindowClose(in id: String): void on thread.main {
    for (const entry of this.nativeWindows) {
      if (entry.value.id == id) {
        // performClose follows AppKit's normal delegate decision path and
        // therefore reaches WindowCloseRequestedEvent before committing.
        entry.value.window.performClose(null);
        return;
      }
    }
  }

  function setWindowTitle(
    in id: String,
    in title: String
  ): void on thread.main {
    for (const entry of this.nativeWindows) {
      if (entry.value.id == id) {
        entry.value.window.title = copy title;
        return;
      }
    }
  }

  function capabilitiesForWindow(
    windowId: i32
  ): Option<CapabilitySelection> on thread.main {
    const found = this.nativeWindows.get(windowId);
    return match (in found) {
      some(window) => Option.some(window.capabilitySelection);
      none => Option.none;
    };
  }

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

  function deliverApplicationWorkerMessage(
    in workerId: String,
    in channel: String,
    in payload: String
  ): void on thread.main {
    for (const entry of this.nativeWindows) {
      if (entry.value.capabilitySelection.allowsWorker(in workerId)) {
        deliverWebViewApplicationWorkerMessage(
          entry.value.webView,
          in workerId,
          in channel,
          in payload
        );
      }
    }
  }

  function deliverResponse(
    in response: BridgeResponse,
    windowId: i32
  ): void on thread.main {
    const activeWindowCount = this.nativeWindows.length;
    const found = this.nativeWindows.get(windowId);
    match (in found) {
      some(window) => deliverWebViewResponse(
        window.webView,
        window.window,
        in response,
        windowId,
        activeWindowCount
      );
      none => {}
    }
  }
}

const application = Once<MacOSApplicationRuntime>();

function recordClosedNativeWindow(
  nativeId: i32
): void on thread.main {
  const current = application.get();
  current.nativeWindowClosed(nativeId);
}

internal function currentMacOSApplication(): MacOSApplicationRuntime {
  return application.get();
}

internal function abortMacOSApplicationRuntime(): void on thread.main {
  const current = application.get();
  current.closeAllNativeWindows();
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
  const current = application.get();
  current.deliverApplicationWorkerMessage(
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
    async move (): void => deliverMacOSApplicationWorkerLifecycle(
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
  routeMessage: DesktopRouteMessageOperation,
  deliverResponse: DesktopDeliverResponseOperation
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
  const value = new MacOSApplicationRuntime({
    name: move name,
    permissions,
    capabilities,
    services: move services,
    updates,
    windowManager,
    routeMessage,
    deliverMessageResponse: deliverResponse,
    applicationWorkers: emptyApplicationWorkers(),
    beginWorkerServiceRequest,
    attachWorkerServiceRequest,
    finishWorkerServiceRequest,
    cancelWorkerServiceRequest,
    cancelAllWorkerServiceRequests,
    nativeWindows: Map<i32, MacOSWindowRuntime>(),
    retiredNativeWindows: Array<MacOSWindowRuntime>(),
    nextNativeWindowId: 1,
  });
  return application.initialize(move value);
}
