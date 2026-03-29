/**
 * App — application lifecycle, events, and configuration.
 *
 * @example
 * ```ts
 * import { App, AppEvent } from "@zappdev/runtime";
 *
 * App.on(AppEvent.REOPEN, () => console.log("dock icon clicked"));
 * App.on(AppEvent.OPEN_URL, (data) => console.log("deep link:", data.url));
 * App.quit();
 * ```
 */

import { getBridge } from "./bridge";
import { Events, AppEvent, eventName } from "./events";

export const App = {
  /** Listen for app lifecycle events. Returns unsubscribe function. */
  on(event: AppEvent, handler: (data?: any) => void): () => void {
    const name = eventName(event);
    return Events.on(name, handler);
  },

  /** Quit the application. */
  quit(): void {
    getBridge().emit("app:quit");
  },

  /** Open a URL in the system browser. */
  openExternal(url: string): void {
    (getBridge() as any).post(JSON.stringify({ t: 4, m: "openExternal", a: { url } }));
  },

  /** Get the app config injected by the native bootstrap. */
  getConfig(): Record<string, unknown> {
    return (globalThis as any)[Symbol.for("zapp.bootstrapConfig")] ?? {};
  },
};
