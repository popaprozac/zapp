import native from "zapp_desktop.h";
import { PreparedApplication } from "../../application-contract.zs";
import {
  ApplicationError,
  PlatformError,
  WindowError,
} from "../../application-error.zs";
import { ApplicationMetadata } from "../../application-metadata.zs";
import { ApplicationContext } from "../../../api/zapp/service.zs";
import { TaskScope } from "std/async";
import { thread } from "std/thread";
import { initializeMacOSApplicationRuntime } from "./runtime.zs";
import { macOSWindowBackend } from "./window-backend.zs";
import {
  zapp_window_blurred_owned,
  zapp_window_closed_owned,
  zapp_window_focused_owned,
  zapp_window_resized_owned,
} from "./window-events.zs";

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
  const prepared = native.zapp_desktop_prepare();
  if (prepared != 0) {
    throw ApplicationError.platform(PlatformError({
      code: prepared,
      message: "could not prepare the macOS application runtime",
    }));
  }
  const context = ApplicationContext({
    metadata: ApplicationMetadata({
      name: copy config.metadata.name,
      identifier: copy config.metadata.identifier,
      version: copy config.metadata.version,
    }),
  });
  const eventUpdates = new TaskScope();
  const lifetime = initializeMacOSApplicationRuntime(
    copy config.metadata.name,
    config.permissions,
    config.capabilities,
    config.services,
    updates,
    eventUpdates,
    windows
  );
  const realized = attempt windows.start(macOSWindowBackend(), true);
  match (realized) {
    success => {}
    failure(windowError) => {
      windows.stop();
      native.zapp_desktop_abort();
      throw ApplicationError.window(windowError);
    }
  }
  const started = attempt config.lifecycles.start(in context);
  match (started) {
    success => {}
    failure(startError) => {
      windows.stop();
      native.zapp_desktop_abort();
      throw ApplicationError.lifecycle(startError);
    }
  }
  const status = native.zapp_desktop_run();
  await eventUpdates.close();
  windows.stop();
  await updates.cancel();
  const stopped = attempt config.lifecycles.stop(in context);
  match (stopped) {
    success => {}
    failure(stopError) => throw ApplicationError.lifecycle(stopError);
  }
  return status;
}
