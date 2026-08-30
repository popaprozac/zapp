import native from "zapp_desktop.h";
import { WindowError } from "../../application-error.zs";
import {
  WindowBackend,
  WindowCreateOperation,
  WindowOperation,
  WindowOptions,
  WindowTitleOperation,
} from "../../window.zs";
import { thread } from "std/thread";
import { currentMacOSApplication } from "./runtime.zs";

function createMacOSWindowDeferred(
  in id: String,
  in options: WindowOptions
): void throws WindowError on thread.main {
  const current = currentMacOSApplication();
  try current.createWindow(in id, in options);
}

function showMacOSWindow(in id: String): void on thread.main {
  native.zapp_desktop_window_show(id);
}

function hideMacOSWindow(in id: String): void on thread.main {
  native.zapp_desktop_window_hide(id);
}

function closeMacOSWindow(in id: String): void on thread.main {
  native.zapp_desktop_window_close(id);
}

function setMacOSWindowTitle(
  in id: String,
  in title: String
): void on thread.main {
  native.zapp_desktop_window_set_title(id, title);
}

internal function macOSWindowBackend(): WindowBackend on thread.main {
  const create: WindowCreateOperation = createMacOSWindowDeferred;
  const show: WindowOperation = showMacOSWindow;
  const hide: WindowOperation = hideMacOSWindow;
  const close: WindowOperation = closeMacOSWindow;
  const setTitle: WindowTitleOperation = setMacOSWindowTitle;
  return WindowBackend({
    create,
    show,
    hide,
    close,
    setTitle,
  });
}
