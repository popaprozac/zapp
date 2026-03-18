import { Events } from "./events";

export interface AppConfig {
  name: string;
  applicationShouldTerminateAfterLastWindowClosed: boolean;
  webContentInspectable: boolean;
  maxWorkers?: number;
}

type AppBridge = {
  getConfig?: () => AppConfig | null;
  appAction?: (action: string) => void;
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

export const App = {
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
};
