/**
 * @module
 * Zapp Runtime — frontend API for Zapp desktop apps.
 *
 * @example
 * ```ts
 * import { App, Window, WindowEvent, Events, Services } from "@zappdev/runtime";
 *
 * const ready = Window.current().subscribe(WindowEvent.READY, () => {
 *     Window.current().show();
 * });
 *
 * // Later, when the listener is no longer needed:
 * ready.unsubscribe();
 *
 * const result = await Services.invoke("greet", { name: "World" });
 * ```
 */

export { App, type PowerState } from "./app";
export { Application, type ApplicationHandle } from "./application-api";
export { Window, Material, createWindow, currentWindow, createWindowHandle, type WindowCreateOptions, type WindowHandle, type WindowEventSubscription, type WindowOptions, type WindowsOptions, type WindowsBackdrop, type WindowsCustomTheme, type MacOptions, type SidebarOptions, type SidebarHandle, type InspectorOptions, type InspectorHandle, type RouterHandle, type RouteOptions, type ToolbarHandle, type ToolbarItemPatch, type ToolbarOptions, type ToolbarItemDef, type ToolbarButtonDef, type ToolbarSegmentedDef, type ToolbarGroupDef, type ToolbarTrackingSepDef, type ToolbarSystemDef, type ToolbarLabelDef } from "./window";
export type { ActionContext, MenuItemPatch } from "./action-context";
export { Screen, type Display, type DisplayRect, type CursorPoint } from "./screen";
export { Webview, ZappWebviewElement, type PanelEvent, type WebviewCreateOptions } from "./webview";
export { Events, WindowEvent, AppEvent, eventName, type WindowPayload, type WindowSizePayload, type EventName, type ModalDismissedPayload, type SidebarResizedPayload, type InspectorResizedPayload, type RouteChangedPayload } from "./events";
export { Services, type InvokeOptions, type CancellablePromise } from "./services";
export { Worker, Workers, type WorkerMessageEvent, type WorkerInfo, type WorkerHandle } from "./worker";
export { Dialog, type OpenFileOptions, type SaveFileOptions, type MessageOptions, type OpenFileResult, type SaveFileResult, type MessageResult } from "./dialog";
export { Menu, type MenuItemDef, type MenuHandle } from "./menu";
export { ContextMenu, type ContextMenuOptions } from "./context-menu";
export { Notification, type NotificationOptions, type ScheduleOptions, type PermissionStatus, type NotificationResponse } from "./notification";
export { Sync, type SyncWaitOptions } from "./sync";
export { Dock } from "./dock";
export { Tray, type TrayOptions, type TrayHandle, type AttachWindowOptions } from "./tray";
export { Clipboard, type ClipboardFormat } from "./clipboard";
export { Shortcuts } from "./shortcuts";
export { Protocols, type ProtocolRequest, type ProtocolResponse, type ProtocolHandler } from "./protocols";
export { Permissions, PermissionDeniedError, type PermissionState } from "./permissions";
export {
  ZappError,
  ZappInvocationError,
  type BridgeErrorPayload,
  type ZappErrorPayload,
} from "./errors";
export { Platform, type PlatformName, type FormFactor, type AppEnv } from "./platform";

// Re-export worker globals type declarations.
// Workers should add: import "@zappdev/runtime/worker-globals";
// This registers send/receive/postMessage/onmessage on the global scope.
