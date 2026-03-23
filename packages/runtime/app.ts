import { Events } from "./events";

/** Configuration for a Zapp application. */
export interface AppConfig {
  /** The display name of the application. */
  name: string;
  /** Whether the app should quit when its last window is closed. */
  applicationShouldTerminateAfterLastWindowClosed: boolean;
  /** Whether web content can be inspected via dev tools. */
  webContentInspectable: boolean;
  /** Maximum number of concurrent workers. */
  maxWorkers?: number;
}

type AppBridge = {
  getConfig?: () => AppConfig | null;
  appAction?: (action: string, payload?: unknown) => void;
};

type ReadyCallback = () => void | Promise<void>;

function getBridge(): AppBridge | null {
  return ((globalThis as unknown as Record<symbol, unknown>)[
    Symbol.for("zapp.bridge")
  ] as AppBridge | undefined) ?? null;
}

function isMainContext(): boolean {
  return (globalThis as unknown as Record<symbol, unknown>)[
    Symbol.for("zapp.context")
  ] !== "worker";
}

const defaultConfig: AppConfig = {
  name: "Zapp App",
  applicationShouldTerminateAfterLastWindowClosed: false,
  webContentInspectable: true,
};

/** Top-level application API for lifecycle, visibility, and configuration. */
export interface AppAPI {
  /** Returns the current application configuration. */
  getConfig(): AppConfig;
  /** Registers a callback to run when the app is ready. */
  onReady(callback: ReadyCallback): void;
  /** Quits the application. */
  quit(): void;
  /** Hides the application. */
  hide(): void;
  /** Shows the application. */
  show(): void;
  /** Opens a URL in the user's default browser. */
  openExternal(url: string): void;
  /** Sets the application menu from a menu definition. */
  setMenu(menu: { items: unknown[] }): void;
}

/** The singleton application API instance. */
export const App: AppAPI = {
  getConfig(): AppConfig {
    return getBridge()?.getConfig?.() ?? defaultConfig;
  },

  onReady(callback: ReadyCallback): void {
    if (!isMainContext()) {
      console.warn("App.onReady() is only available in the main/webview context.");
      return;
    }
    Events.on("ready", callback);
  },

  quit(): void {
    getBridge()?.appAction?.("quit");
  },

  hide(): void {
    getBridge()?.appAction?.("hide");
  },

  show(): void {
    getBridge()?.appAction?.("show");
  },

  openExternal(url: string): void {
    getBridge()?.appAction?.("openExternal", { url });
  },

  setMenu(menu: { items: unknown[] }): void {
    getBridge()?.appAction?.("setMenu", { items: menu.items });
  },
};
