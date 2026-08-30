import { thread } from "std/thread";
import { currentMacOSApplication } from "./runtime.zs";

export c function zapp_window_closed_owned(
  windowId: String,
  nativeId: i32
): void {
  const current = currentMacOSApplication();
  const eventUpdates = current.eventUpdates;
  const id = copy windowId;
  const cleanup = eventUpdates.schedule(
    thread.main,
    async move (): void => closeNativeWindow(in id, nativeId)
  );
  if (!cleanup.accepted) return;
}

export c function zapp_window_focused_owned(
  windowId: String,
  nativeId: i32
): void {
  const current = currentMacOSApplication();
  const eventUpdates = current.eventUpdates;
  const id = copy windowId;
  const update = eventUpdates.schedule(
    thread.main,
    async move (): void => focusNativeWindow(in id, nativeId)
  );
  if (!update.accepted) return;
}

export c function zapp_window_blurred_owned(
  windowId: String,
  nativeId: i32
): void {
  const current = currentMacOSApplication();
  const eventUpdates = current.eventUpdates;
  const id = copy windowId;
  const update = eventUpdates.schedule(
    thread.main,
    async move (): void => blurNativeWindow(in id, nativeId)
  );
  if (!update.accepted) return;
}

export c function zapp_window_resized_owned(
  windowId: String,
  nativeId: i32,
  width: u32,
  height: u32
): void {
  const current = currentMacOSApplication();
  const eventUpdates = current.eventUpdates;
  const id = copy windowId;
  const update = eventUpdates.schedule(
    thread.main,
    async move (): void => resizeNativeWindow(
      in id,
      nativeId,
      width,
      height
    )
  );
  if (!update.accepted) return;
}

function closeNativeWindow(
  in windowId: String,
  nativeId: i32
): void on thread.main {
  const current = currentMacOSApplication();
  current.closeWindow(nativeId, in windowId);
}

function focusNativeWindow(
  in windowId: String,
  nativeId: i32
): void on thread.main {
  const current = currentMacOSApplication();
  current.focusWindow(in windowId);
}

function blurNativeWindow(
  in windowId: String,
  nativeId: i32
): void on thread.main {
  const current = currentMacOSApplication();
  current.blurWindow(in windowId);
}

function resizeNativeWindow(
  in windowId: String,
  nativeId: i32,
  width: u32,
  height: u32
): void on thread.main {
  const current = currentMacOSApplication();
  current.resizeWindow(in windowId, width, height);
}
