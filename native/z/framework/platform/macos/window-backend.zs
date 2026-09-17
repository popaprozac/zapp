import { WindowError } from "../../application-error.zs";
import { WindowSize } from "../../events.zs";
import { WindowPosition } from "../../window-positioning.zs";
import { Bounds, Display } from "../../window-display.zs";
import {
  WindowBackend,
  WindowCreateOperation,
  WindowBooleanOperation,
  WindowOperation,
  WindowOptions,
  WindowTitleOperation,
} from "../../window.zs";
import { thread } from "std/thread";
import { currentMacOSApplication } from "./application-runtime.zs";
import { showMacOSContextMenu } from "./context-menu-backend.zs";

function createMacOSWindowDeferred(
  in id: String,
  in options: WindowOptions
): void throws WindowError on thread.main {
  const current = currentMacOSApplication();
  try current.windows.createWindow(in id, in options);
}

function showMacOSWindow(in id: String): void on thread.main {
  const current = currentMacOSApplication();
  current.windows.showWindow(in id);
}

function hideMacOSWindow(in id: String): void on thread.main {
  const current = currentMacOSApplication();
  current.windows.hideWindow(in id);
}

function focusMacOSWindow(in id: String): void on thread.main {
  const current = currentMacOSApplication();
  current.windows.focusWindow(in id);
}

function minimizeMacOSWindow(in id: String): void on thread.main {
  const current = currentMacOSApplication();
  current.windows.minimizeWindow(in id);
}

function unminimizeMacOSWindow(in id: String): void on thread.main {
  const current = currentMacOSApplication();
  current.windows.unminimizeWindow(in id);
}

function setMacOSWindowMaximized(in id: String, value: boolean): void on thread.main {
  const current = currentMacOSApplication();
  current.windows.setWindowMaximized(in id, value);
}

function setMacOSWindowFullscreen(in id: String, value: boolean): void on thread.main {
  const current = currentMacOSApplication();
  current.windows.setWindowFullscreen(in id, value);
}

function closeMacOSWindow(in id: String): void on thread.main {
  const current = currentMacOSApplication();
  current.windows.requestWindowClose(in id);
}

function getMacOSWindowSize(in id: String): WindowSize throws WindowError on thread.main {
  const current = currentMacOSApplication();
  return try current.windows.getWindowSize(in id);
}

function getMacOSWindowPosition(in id: String): WindowPosition throws WindowError on thread.main {
  const current = currentMacOSApplication();
  return try current.windows.getWindowPosition(in id);
}

function getMacOSWindowBounds(in id: String): Bounds throws WindowError on thread.main {
  const current = currentMacOSApplication();
  return try current.windows.getWindowBounds(in id);
}

function getMacOSWindowDisplay(in id: String): Option<Display> throws WindowError on thread.main {
  const current = currentMacOSApplication();
  return try current.windows.getWindowDisplay(in id);
}

function setMacOSWindowPosition(in id: String, position: WindowPosition): void throws WindowError on thread.main {
  const current = currentMacOSApplication();
  try current.windows.setWindowPosition(in id, position);
}

function centerMacOSWindow(in id: String): void throws WindowError on thread.main {
  const current = currentMacOSApplication();
  try current.windows.centerWindow(in id);
}

function setMacOSWindowSize(in id: String, size: WindowSize): void throws WindowError on thread.main {
  const current = currentMacOSApplication();
  try current.windows.setWindowSize(in id, size);
}

function setMacOSWindowTitle(
  in id: String,
  in title: String
): void on thread.main {
  const current = currentMacOSApplication();
  current.windows.setWindowTitle(in id, in title);
}

internal function macOSWindowBackend(): WindowBackend on thread.main {
  const create: WindowCreateOperation = createMacOSWindowDeferred;
  const show: WindowOperation = showMacOSWindow;
  const focus: WindowOperation = focusMacOSWindow;
  const minimize: WindowOperation = minimizeMacOSWindow;
  const unminimize: WindowOperation = unminimizeMacOSWindow;
  const setMaximized: WindowBooleanOperation = setMacOSWindowMaximized;
  const setFullscreen: WindowBooleanOperation = setMacOSWindowFullscreen;
  const hide: WindowOperation = hideMacOSWindow;
  const close: WindowOperation = closeMacOSWindow;
  const setTitle: WindowTitleOperation = setMacOSWindowTitle;
  return WindowBackend({
    create,
    show,
    focus,
    minimize,
    unminimize,
    setMaximized,
    setFullscreen,
    hide,
    close,
    setTitle,
    getSize: getMacOSWindowSize,
    setSize: setMacOSWindowSize,
    getPosition: getMacOSWindowPosition,
    getBounds: getMacOSWindowBounds,
    getDisplay: getMacOSWindowDisplay,
    setPosition: setMacOSWindowPosition,
    center: centerMacOSWindow,
    showContextMenu: showMacOSContextMenu,
  });
}
