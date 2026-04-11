/**
 * @module
 * Zapp Runtime — frontend API for Zapp desktop apps.
 *
 * @example
 * ```ts
 * import { App, Window, WindowEvent, Events, Services } from "@zappdev/runtime";
 *
 * Window.current().on(WindowEvent.READY, () => {
 *     Window.current().show();
 * });
 *
 * const result = await Services.invoke("greet", { name: "World" });
 * ```
 */

export { App } from "./app";
export { Window, type WindowHandle, type WindowOptions } from "./window";
export { Events, WindowEvent, AppEvent, eventName, type WindowPayload, type WindowSizePayload, type EventName } from "./events";
export { Services, type InvokeOptions, type CancellablePromise } from "./services";
export { Worker, SharedWorker, SharedWorkerPort, type WorkerMessageEvent } from "./worker";
export { Dialog, type OpenFileOptions, type SaveFileOptions, type MessageOptions, type OpenFileResult, type SaveFileResult, type MessageResult } from "./dialog";
export { Menu, type MenuItemDef, type MenuHandle } from "./menu";
export { ContextMenu, type ContextMenuOptions } from "./context-menu";
export { Notification, type NotificationOptions, type ScheduleOptions, type PermissionStatus } from "./notification";
export { Sync, type SyncWaitOptions } from "./sync";
export { Dock } from "./dock";

// Re-export worker globals type declarations.
// Workers should add: import "@zappdev/runtime/worker-globals";
// This registers send/receive/postMessage/onmessage on the global scope.
