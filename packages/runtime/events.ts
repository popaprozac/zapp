type EventHandler = (payload: unknown) => void;

type ZappGlobal = {
  emit: (name: string, payload?: unknown) => unknown;
  on: (name: string, handler: EventHandler) => (() => void) | void;
};

function getZapp(): ZappGlobal {
  const z = (globalThis as { __zapp?: ZappGlobal }).__zapp;
  if (!z) {
    throw new Error("__zapp is unavailable. Is the bridge initialized?");
  }
  return z;
}

export interface EventsAPI {
  emit(name: string, payload?: unknown): unknown;
  on(name: string, handler: EventHandler): () => void;
}

export const Events: EventsAPI = {
  emit(name: string, payload?: unknown): unknown {
    return getZapp().emit(name, payload);
  },
  on(name: string, handler: EventHandler): () => void {
    const off = getZapp().on(name, handler);
    return typeof off === "function" ? off : () => {};
  },
};
