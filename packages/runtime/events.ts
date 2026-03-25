/** Numeric identifiers for window lifecycle and state-change events. */
export enum WindowEvent {
    /** The window has finished loading and is ready. */
    READY = 0,
    /** The window gained input focus. */
    FOCUS = 1,
    /** The window lost input focus. */
    BLUR = 2,
    /** The window was resized. */
    RESIZE = 3,
    /** The window was moved. */
    MOVE = 4,
    /** The window close was requested. */
    CLOSE = 5,
    /** The window was minimized. */
    MINIMIZE = 6,
    /** The window was maximized. */
    MAXIMIZE = 7,
    /** The window was restored from minimize or maximize. */
    RESTORE = 8,
    /** The window entered fullscreen mode. */
    FULLSCREEN = 9,
    /** The window exited fullscreen mode. */
    UNFULLSCREEN = 10,
}

/** Numeric identifiers for application lifecycle events. */
export enum AppEvent {
    /** The application has started. */
    STARTED = 100,
    /** The application is shutting down. */
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

/** Base payload delivered with window events. */
export interface WindowEventPayload {
    /** The ID of the window that emitted the event. */
    windowId: string;
    /** Unix-epoch millisecond timestamp of when the event occurred. */
    timestamp: number;
    /** Window dimensions, present on size-related events. */
    size?: { width: number; height: number };
    /** Window screen coordinates, present on position-related events. */
    position?: { x: number; y: number };
}

/** Payload for events that always include size and position (resize, move, maximize, restore) */
export interface WindowSizeEventPayload {
    windowId: string;
    timestamp: number;
    size: { width: number; height: number };
    position: { x: number; y: number };
}

// ---------------------------------------------------------------------------
// Known event name → payload type mapping
// ---------------------------------------------------------------------------

/** Window events that carry size + position data */
type WindowSizeEvents =
    | "window:resize"
    | "window:move"
    | "window:maximize"
    | "window:restore";

/** Window events without size/position data */
type WindowSimpleEvents =
    | "window:ready"
    | "window:focus"
    | "window:blur"
    | "window:close"
    | "window:minimize"
    | "window:fullscreen"
    | "window:unfullscreen";

/** App lifecycle events */
type AppEvents =
    | "app:started"
    | "app:shutdown";

/** Deep link event — app opened via custom URL scheme */
type DeepLinkEvents = "app:open-url";

/** Payload for deep link events */
export interface DeepLinkPayload {
    /** The full URL that opened the app (e.g., "myapp://callback?code=...") */
    url: string;
}

/** All known Zapp event names */
export type KnownEventName = WindowSizeEvents | WindowSimpleEvents | AppEvents | DeepLinkEvents;

/** Resolve the payload type for a given event name */
export type EventPayloadFor<T extends string> =
    T extends WindowSizeEvents ? WindowSizeEventPayload :
    T extends WindowSimpleEvents ? WindowEventPayload :
    T extends DeepLinkEvents ? DeepLinkPayload :
    T extends AppEvents ? undefined :
    unknown;

/** Event name type — known names get autocomplete, arbitrary strings still work */
export type EventName = KnownEventName | (string & {});

/** Type-safe event emitter API for subscribing to and emitting Zapp events. */
export interface EventsAPI {
    /** Emit a named event with an optional payload. */
    emit(name: string, payload?: unknown): unknown;

    /** Subscribe to a window size/position event. Returns an unsubscribe function. */
    on(name: WindowSizeEvents, handler: (payload: WindowSizeEventPayload) => void): () => void;
    /** Subscribe to a simple window event. Returns an unsubscribe function. */
    on(name: WindowSimpleEvents, handler: (payload: WindowEventPayload) => void): () => void;
    /** Subscribe to an app lifecycle event. Returns an unsubscribe function. */
    on(name: AppEvents, handler: () => void): () => void;
    /** Subscribe to a custom event. Returns an unsubscribe function. */
    on(name: string & {}, handler: (payload?: unknown) => void): () => void;

    /** Subscribe to a window size/position event once. Returns an unsubscribe function. */
    once(name: WindowSizeEvents, handler: (payload: WindowSizeEventPayload) => void): () => void;
    /** Subscribe to a simple window event once. Returns an unsubscribe function. */
    once(name: WindowSimpleEvents, handler: (payload: WindowEventPayload) => void): () => void;
    /** Subscribe to an app lifecycle event once. Returns an unsubscribe function. */
    once(name: AppEvents, handler: () => void): () => void;
    /** Subscribe to a custom event once. Returns an unsubscribe function. */
    once(name: string & {}, handler: (payload?: unknown) => void): () => void;

    /** Remove a specific handler, or all handlers, for the given event name. */
    off(name: EventName, handler?: EventHandler): void;
    /** Remove all handlers for a given event name, or all events if no name is provided. */
    offAll(name?: EventName): void;
}

/** The singleton event bus for emitting, subscribing to, and removing event listeners. */
export const Events = {
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
} satisfies Record<string, unknown> as EventsAPI;

/** Resolve a {@link WindowEvent} enum member to its string event name. */
export function getWindowEventName(event: WindowEvent): string {
    return WINDOW_EVENT_NAMES[event] ?? `window:${event}`;
}

/** Resolve an {@link AppEvent} enum member to its string event name. */
export function getAppEventName(event: AppEvent): string {
    return APP_EVENT_NAMES[event] ?? `app:${event}`;
}
