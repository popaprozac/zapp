import { App as RuntimeApp, type AppConfig } from "@zapp/runtime";

type AppBridge = {
  appAction?: (action: string) => void;
  appConfigure?: (config: Partial<AppConfig>) => void;
  mergeConfig?: (config: Partial<AppConfig>) => void;
};

function getBridge(): AppBridge | null {
  return ((globalThis as unknown as Record<symbol, unknown>)[
    Symbol.for("zapp.bridge")
  ] as AppBridge | undefined) ?? null;
}

function isBackendContext(): boolean {
  return (globalThis as unknown as Record<symbol, unknown>)[
    Symbol.for("zapp.context")
  ] === "backend";
}

type ReadyCallback = () => void | Promise<void>;
const readyCallbacks: ReadyCallback[] = [];
let readyFired = false;
let configured = false;

export const App = {
  getConfig(): AppConfig {
    return RuntimeApp.getConfig();
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

  configure(config: Partial<AppConfig>): void {
    if (!isBackendContext()) {
      throw new Error("App.configure() is only available in the backend context.");
    }
    if (configured) {
      throw new Error("App.configure() can only be called once, before the app runs.");
    }
    configured = true;
    const b = getBridge();
    b?.mergeConfig?.(config);
    b?.appConfigure?.(config);
  },

  onReady(callback: ReadyCallback): void {
    if (readyFired) {
      try { callback(); } catch { /* isolate */ }
      return;
    }
    readyCallbacks.push(callback);
  },

  /** @internal Called by the framework when the backend is ready. */
  _fireReady(): void {
    if (readyFired) return;
    readyFired = true;
    for (const cb of readyCallbacks) {
      try { cb(); } catch { /* isolate */ }
    }
    readyCallbacks.length = 0;
  },
};
