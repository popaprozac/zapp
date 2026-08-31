import { WindowError } from "../../application-error.zs";
import {
  WindowBackend,
  WindowCreateOperation,
  WindowOperation,
  WindowOptions,
  WindowTitleOperation,
} from "../../window.zs";
import { thread } from "std/thread";
import { currentMacOSApplication } from "./application-runtime.zs";

function createMacOSWindowDeferred(
  in id: String,
  in options: WindowOptions
): void throws WindowError on thread.main {
  const current = currentMacOSApplication();
  try current.createWindow(in id, in options);
}

function showMacOSWindow(in id: String): void on thread.main {
  const current = currentMacOSApplication();
  current.showWindow(in id);
}

function hideMacOSWindow(in id: String): void on thread.main {
  const current = currentMacOSApplication();
  current.hideWindow(in id);
}

function closeMacOSWindow(in id: String): void on thread.main {
  const current = currentMacOSApplication();
  current.requestWindowClose(in id);
}

function setMacOSWindowTitle(
  in id: String,
  in title: String
): void on thread.main {
  const current = currentMacOSApplication();
  current.setWindowTitle(in id, in title);
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
