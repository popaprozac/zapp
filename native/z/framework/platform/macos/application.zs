import { PreparedApplication } from "../../application-contract.zs";
import {
  ApplicationError,
  WindowError,
} from "../../application-error.zs";
import { ApplicationMetadata } from "../../application-metadata.zs";
import { ApplicationContext } from "../../../api/zapp/service.zs";
import { TaskScope } from "std/async";
import { thread } from "std/thread";
import {
  abortMacOSApplicationRuntime,
  installMacOSApplicationWorkers,
  publishMacOSApplicationWorkerMessage,
} from "./application-runtime.zs";
import { initializeMacOSApplicationRuntime } from "./runtime.zs";
import {
  initializeMacOSApplicationHost,
  runMacOSApplicationLoop,
} from "./application-host.zs";
import { macOSWindowBackend } from "./window-backend.zs";
import {
  startConfiguredApplicationWorkers,
} from "../../configured-application.zs";
import {
  ApplicationWorkerMessageHandler,
} from "../../worker/application-workers.zs";

export async function runMacOSApplication(
  config: PreparedApplication,
  updates: TaskScope
): i32 throws ApplicationError on thread.main {
  let windows = config.windows;
  const registeredWindows = windows.all();
  if (registeredWindows.length == 0) {
    throw ApplicationError.window(WindowError({
      id: "",
      message: "a macOS desktop application requires a registered window in this tier",
    }));
  }
  const hostLifetime = initializeMacOSApplicationHost();
  const context = ApplicationContext({
    metadata: ApplicationMetadata({
      name: copy config.metadata.name,
      identifier: copy config.metadata.identifier,
      version: copy config.metadata.version,
    }),
  });
  const lifetime = initializeMacOSApplicationRuntime(
    copy config.metadata.name,
    config.permissions,
    config.capabilities,
    config.services,
    updates,
    windows
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
  const started = attempt config.lifecycles.start(in context);
  match (started) {
    success => {}
    failure(startError) => {
      windows.stop();
      abortMacOSApplicationRuntime();
      throw ApplicationError.lifecycle(startError);
    }
  }
  const workerMessages: ApplicationWorkerMessageHandler =
    publishMacOSApplicationWorkerMessage;
  const workers = startConfiguredApplicationWorkers(
    config.workers,
    workerMessages
  );
  installMacOSApplicationWorkers(workers);
  const status = runMacOSApplicationLoop();
  workers.requestCancellation();
  workers.join();
  windows.stop();
  await updates.cancel();
  const stopped = attempt config.lifecycles.stop(in context);
  match (stopped) {
    success => {}
    failure(stopError) => throw ApplicationError.lifecycle(stopError);
  }
  return status;
}
