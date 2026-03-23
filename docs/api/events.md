# Events API

The `Events` module provides a cross-context event system. Events can be emitted and received across webviews, workers, and the backend process. Known event names (such as `WindowEvent` values) provide full type inference, while arbitrary string names remain supported for application-defined events.

## Import

```typescript
import { Events, WindowEvent, AppEvent } from "@zapp/runtime";
```

## Methods

| Method | Signature | Description |
|--------|-----------|-------------|
| `Events.on` | `(event, callback) => void` | Subscribes to an event. The callback type is inferred from the event name. |
| `Events.once` | `(event, callback) => void` | Subscribes to an event for a single firing, then automatically unsubscribes. |
| `Events.off` | `(event, callback) => void` | Removes a specific callback from an event. |
| `Events.offAll` | `(event?) => void` | Removes all listeners for an event, or all listeners entirely if no event is given. |
| `Events.emit` | `(event, payload?) => void` | Emits an event with an optional payload. The event is delivered to all contexts. |

## Typed Overloads

`Events.on()` and `Events.once()` use overloaded signatures so that known event names produce typed payloads automatically.

```typescript
// Window size events -> WindowSizeEventPayload
Events.on(WindowEvent.RESIZE, (event) => {
  event.width;  // number
  event.height; // number
});

// Window simple events -> WindowEventPayload
Events.on(WindowEvent.FOCUS, (event) => {
  event.windowId; // number
});

// App events -> AppEventPayload
Events.on(AppEvent.READY, (event) => {
  // ...
});

// Custom string events -> unknown payload (you provide the type)
Events.on("my-custom-event", (data: { count: number }) => {
  console.log(data.count);
});
```

Known event names get autocomplete in your editor. Arbitrary strings still work and accept any payload type.

## WindowEvent Enum

| Value | Typed Payload |
|-------|---------------|
| `WindowEvent.CLOSE_REQUESTED` | `WindowEventPayload` |
| `WindowEvent.CLOSED` | `WindowEventPayload` |
| `WindowEvent.FOCUS` | `WindowEventPayload` |
| `WindowEvent.BLUR` | `WindowEventPayload` |
| `WindowEvent.RESIZE` | `WindowSizeEventPayload` |
| `WindowEvent.MOVE` | `WindowSizeEventPayload` |
| `WindowEvent.MINIMIZE` | `WindowEventPayload` |
| `WindowEvent.MAXIMIZE` | `WindowEventPayload` |
| `WindowEvent.RESTORE` | `WindowEventPayload` |
| `WindowEvent.ENTER_FULLSCREEN` | `WindowEventPayload` |
| `WindowEvent.EXIT_FULLSCREEN` | `WindowEventPayload` |

## Payload Types

```typescript
interface WindowEventPayload {
  windowId: number;
}

interface WindowSizeEventPayload {
  windowId: number;
  width: number;
  height: number;
  x: number;
  y: number;
}
```

## Examples

### Subscribing to window events

```typescript
import { Events, WindowEvent } from "@zapp/runtime";

Events.on(WindowEvent.FOCUS, (event) => {
  console.log(`Window ${event.windowId} focused`);
});
```

### One-time listener

```typescript
Events.once(WindowEvent.CLOSED, (event) => {
  console.log(`Window ${event.windowId} closed`);
});
```

### Custom application events

```typescript
// In one context (e.g. a worker)
Events.emit("data-updated", { table: "users", count: 42 });

// In another context (e.g. a webview)
Events.on("data-updated", (data: { table: string; count: number }) => {
  refreshUI(data.table);
});
```

### Removing listeners

```typescript
function onResize(event: WindowSizeEventPayload) {
  console.log(event.width, event.height);
}

Events.on(WindowEvent.RESIZE, onResize);

// Later:
Events.off(WindowEvent.RESIZE, onResize);

// Or remove all resize listeners:
Events.offAll(WindowEvent.RESIZE);

// Or remove everything:
Events.offAll();
```

## Cross-Context Behavior

Events are delivered across all contexts in the application:

- **Webview to webview**: A webview can emit an event that another webview receives.
- **Worker to webview**: Workers can emit events consumed by UI code.
- **Backend to frontend**: Native-side events (like window events) are delivered to all subscribed contexts.

No additional configuration is needed. All calls to `Events.emit()` broadcast to every context that has a matching listener.
