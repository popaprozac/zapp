/**
 * @module
 * Frontend runtime API for Zapp desktop apps.
 *
 * Provides window management, events, dialogs, menus, workers, sync primitives,
 * and service invocation for building cross-platform desktop applications.
 *
 * @example
 * ```ts
 * import { App, Window, WindowEvent, Dialog, Menu, Events } from "@zapp/runtime";
 *
 * Window.current().on(WindowEvent.READY, () => {
 *     Window.current().show();
 * });
 *
 * const result = await Dialog.message({
 *     message: "Hello from Zapp!",
 *     buttons: ["OK"],
 * });
 * ```
 */

export { App } from "./app";
export type { AppAPI, AppConfig } from "./app";
export { Events, WindowEvent, AppEvent, getWindowEventName, getAppEventName } from "./events";
export type { EventsAPI, WindowEventPayload, WindowSizeEventPayload, EventName, KnownEventName, EventPayloadFor } from "./events";
export { Window } from "./windows";
export type { WindowAPI, WindowOptions, WindowHandle } from "./windows";
export { Worker, SharedWorker } from "./worker";
export { Services } from "./services";
export type { ServicesAPI } from "./services";
export { Sync } from "./sync";
export type { SyncAPI, SyncWaitOptions } from "./sync";
export { Dialog } from "./dialog";
export type { DialogAPI, OpenFileOptions, SaveFileOptions, MessageOptions, FileFilter, OpenFileResult, SaveFileResult, MessageResult } from "./dialog";
export { Menu } from "./menu";
export type { MenuAPI, MenuItemDef, MenuHandle } from "./menu";
export * from "./protocol";
export * from "./bindings-contract";
