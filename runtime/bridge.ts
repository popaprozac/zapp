/**
 * Bridge accessor — internal module, not exported to users.
 * All runtime modules talk to native through this.
 */

const BRIDGE_KEY = Symbol.for("zapp.bridge");

export interface ZappBridge {
  invoke(method: string, args?: Record<string, unknown>, opts?: { timeout?: number }): Promise<unknown> & { cancel(): void };
  emit(name: string, payload?: Record<string, unknown>): void;
  on(name: string, handler: (payload: unknown) => void): () => void;
  _onInvokeResult(id: number, ok: boolean, payload: string): void;
  _onEvent(name: string, payload: string): void;
  dispatchWindowEvent(windowId: string, eventName: string, dataJson?: string): void;
  dispatchPanelEvent(panelId: string, eventName: string, dataJson?: string): void;
  createWorker(scriptUrl: string, opts?: { engine?: string; name?: string }): string;
  listWorkers(): Promise<unknown> | string;
}

export function getBridge(): ZappBridge {
  const bridge = (globalThis as any)[BRIDGE_KEY] as ZappBridge | undefined;
  if (!bridge) {
    throw new Error("[zapp] Bridge not available. Is the app running in a Zapp WebView?");
  }
  return bridge;
}
