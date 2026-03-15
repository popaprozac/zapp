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

function getBridge(): AppBridge | null {
  return ((globalThis as unknown as Record<symbol, unknown>)[
    Symbol.for("zapp.bridge")
  ] as AppBridge | undefined) ?? null;
}

const defaultConfig: AppConfig = {
  name: "Zapp App",
  applicationShouldTerminateAfterLastWindowClosed: false,
  webContentInspectable: true,
};

export interface AppAPI {
  getConfig(): AppConfig;
  quit(): void;
  hide(): void;
  show(): void;
}

export const App: AppAPI = {
  getConfig(): AppConfig {
    return getBridge()?.getConfig?.() ?? defaultConfig;
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
