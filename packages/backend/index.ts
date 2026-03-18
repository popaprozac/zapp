// Guard: Ensure this package is only loaded in the backend context
const isBackendContext = (): boolean => {
  return (globalThis as unknown as Record<symbol, unknown>)[
    Symbol.for("zapp.context")
  ] === "backend";
};

if (!isBackendContext()) {
  throw new Error("@zapp/backend can only be used in the backend context. It is not available in webview or worker contexts.");
}

export { App } from "./app";
export { Window } from "@zapp/runtime";
export type { WindowOptions, WindowHandle } from "@zapp/runtime";
export { Events } from "@zapp/runtime";
export { Services } from "@zapp/runtime";
export { Sync } from "@zapp/runtime";
