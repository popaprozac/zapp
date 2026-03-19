export enum WindowEvent {
    READY = 0,
    FOCUS = 1,
    BLUR = 2,
    RESIZE = 3,
    MOVE = 4,
    CLOSE = 5,
    MINIMIZE = 6,
    MAXIMIZE = 7,
    RESTORE = 8,
    FULLSCREEN = 9,
    UNFULLSCREEN = 10,
}

export enum AppEvent {
    STARTED = 100,
    SHUTDOWN = 101,
}

const WINDOW_EVENT_NAMES: Record<number, string> = {
    [WindowEvent.READY]: "ready",
    [WindowEvent.FOCUS]: "focus",
    [WindowEvent.BLUR]: "blur",
    [WindowEvent.RESIZE]: "resize",
    [WindowEvent.MOVE]: "move",
    [WindowEvent.CLOSE]: "close",
    [WindowEvent.MINIMIZE]: "minimize",
    [WindowEvent.MAXIMIZE]: "maximize",
    [WindowEvent.RESTORE]: "restore",
    [WindowEvent.FULLSCREEN]: "fullscreen",
    [WindowEvent.UNFULLSCREEN]: "unfullscreen",
};

const APP_EVENT_NAMES: Record<number, string> = {
    [AppEvent.STARTED]: "app:started",
    [AppEvent.SHUTDOWN]: "app:shutdown",
};

type EventHandler = (payload?: unknown) => void;

type ZappBridge = {
    _listeners?: Record<string, Array<{ id: number; fn: EventHandler; once?: boolean }>>;
    _lastId?: number;
    _emit?: (name: string, payload: unknown) => boolean;
    _onEvent?: (name: string, handler: EventHandler) => number;
    _offEvent?: (name: string, id: number) => void;
    _onceEvent?: (name: string, handler: EventHandler) => number;
    _offAllEvents?: (name?: string) => void;
};

const BRIDGE_SYMBOL = Symbol.for("zapp.bridge");

const getBridge = (): ZappBridge => {
    const bridge = (globalThis as unknown as Record<symbol, unknown>)[BRIDGE_SYMBOL] as ZappBridge | undefined;
    if (!bridge) {
        throw new Error("Zapp bridge is unavailable. Is the bootstrap loaded?");
    }
    return bridge;
};

const ensureBridge = (): ZappBridge => {
    const symbolStore = globalThis as unknown as Record<symbol, unknown>;
    let bridge = symbolStore[BRIDGE_SYMBOL] as ZappBridge | undefined;
    if (!bridge) {
        bridge = { _listeners: {}, _lastId: 0 };
        try {
            Object.defineProperty(symbolStore, BRIDGE_SYMBOL, {
                value: bridge, enumerable: false, configurable: true, writable: false,
            });
        } catch {
            // @ts-ignore -- fallback for non-configurable
            symbolStore[BRIDGE_SYMBOL] = bridge;
        }
    }
    if (!bridge._listeners) bridge._listeners = {};
    return bridge;
};

export interface WindowEventPayload {
    windowId: string;
    timestamp: number;
    size?: { width: number; height: number };
    position?: { x: number; y: number };
}

export interface EventsAPI {
    emit(name: string, payload?: unknown): unknown;
    on(name: string, handler: EventHandler): () => void;
    once(name: string, handler: EventHandler): () => void;
    off(name: string, handler?: EventHandler): void;
    offAll(name?: string): void;
}

export const Events: EventsAPI = {
    emit(name: string, payload?: unknown): unknown {
        return getBridge()._emit?.(name, payload);
    },

    on(name: string, handler: EventHandler): () => void {
        const bridge = ensureBridge();
        if (bridge._onEvent) {
            const id = bridge._onEvent(name, handler);
            return () => bridge._offEvent?.(name, id);
        }
        const listeners = bridge._listeners!;
        const id = (bridge._lastId = (bridge._lastId ?? 0) + 1);
        (listeners[name] ??= []).push({ id, fn: handler });
        return () => {
            listeners[name] = (listeners[name] ?? []).filter((e) => e.id !== id);
        };
    },

    once(name: string, handler: EventHandler): () => void {
        const bridge = ensureBridge();
        if (bridge._onceEvent) {
            const id = bridge._onceEvent(name, handler);
            return () => bridge._offEvent?.(name, id);
        }
        const listeners = bridge._listeners!;
        const id = (bridge._lastId = (bridge._lastId ?? 0) + 1);
        (listeners[name] ??= []).push({ id, fn: handler, once: true });
        return () => {
            listeners[name] = (listeners[name] ?? []).filter((e) => e.id !== id);
        };
    },

    off(name: string, handler?: EventHandler): void {
        const bridge = getBridge();
        if (!handler) {
            bridge._offAllEvents?.(name) ??
                ((bridge._listeners ?? {})[name] = []);
            return;
        }
        const listeners = bridge._listeners ?? {};
        listeners[name] = (listeners[name] ?? []).filter((e) => e.fn !== handler);
    },

    offAll(name?: string): void {
        const bridge = getBridge();
        if (bridge._offAllEvents) {
            bridge._offAllEvents(name);
            return;
        }
        if (name) {
            (bridge._listeners ?? {})[name] = [];
        } else {
            bridge._listeners = {};
        }
    },
};

export function getWindowEventName(event: WindowEvent): string {
    return WINDOW_EVENT_NAMES[event] ?? `window:${event}`;
}

export function getAppEventName(event: AppEvent): string {
    return APP_EVENT_NAMES[event] ?? `app:${event}`;
}
