# Window API

The `Window` module provides creation and management of native desktop windows. Each window hosts a webview and can be configured with size, position, appearance, and behavior options.

## Import

```typescript
import { Window, WindowEvent } from "@zapp/runtime";
```

## Static Methods

| Method | Signature | Description |
|--------|-----------|-------------|
| `Window.create` | `(options?: WindowOptions) => WindowHandle` | Creates a new native window with the given options. |
| `Window.current` | `() => WindowHandle` | Returns a handle to the window that owns the current webview context. Throws in worker contexts. |

## WindowHandle Methods

| Method | Signature | Description |
|--------|-----------|-------------|
| `show` | `() => void` | Makes the window visible. |
| `hide` | `() => void` | Hides the window without closing it. |
| `minimize` | `() => void` | Minimizes the window to the taskbar or Dock. |
| `maximize` | `() => void` | Maximizes the window to fill the screen. |
| `close` | `() => void` | Requests the window to close. If a `CLOSE_REQUESTED` listener calls `event.preventDefault()`, the close is cancelled. |
| `destroy` | `() => void` | Immediately destroys the window, bypassing any close-prevention listeners. |
| `setTitle` | `(title: string) => void` | Sets the window title bar text. |
| `setSize` | `(width: number, height: number) => void` | Sets the window content size in logical pixels. |
| `setPosition` | `(x: number, y: number) => void` | Sets the window position in screen coordinates. |
| `setFullscreen` | `(enabled: boolean) => void` | Enters or exits fullscreen mode. |
| `setAlwaysOnTop` | `(enabled: boolean) => void` | Pins or unpins the window above all other windows. |

## Types

### WindowOptions

```typescript
interface WindowOptions {
  title?: string;
  width?: number;
  height?: number;
  minWidth?: number;
  minHeight?: number;
  maxWidth?: number;
  maxHeight?: number;
  x?: number;
  y?: number;
  resizable?: boolean;
  fullscreen?: boolean;
  alwaysOnTop?: boolean;
  decorations?: boolean;
  transparent?: boolean;
  visible?: boolean;
  url?: string;
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `title` | `string` | `""` | Window title bar text. |
| `width` | `number` | `800` | Initial content width in logical pixels. |
| `height` | `number` | `600` | Initial content height in logical pixels. |
| `minWidth` | `number` | `0` | Minimum resizable width. |
| `minHeight` | `number` | `0` | Minimum resizable height. |
| `maxWidth` | `number` | `0` (unbounded) | Maximum resizable width. `0` means no limit. |
| `maxHeight` | `number` | `0` (unbounded) | Maximum resizable height. `0` means no limit. |
| `x` | `number` | centered | Initial x position in screen coordinates. |
| `y` | `number` | centered | Initial y position in screen coordinates. |
| `resizable` | `boolean` | `true` | Whether the user can resize the window. |
| `fullscreen` | `boolean` | `false` | Start in fullscreen mode. |
| `alwaysOnTop` | `boolean` | `false` | Keep the window above all others. |
| `decorations` | `boolean` | `true` | Show native title bar and window chrome. |
| `transparent` | `boolean` | `false` | Enable transparent window background. |
| `visible` | `boolean` | `true` | Show the window immediately after creation. |
| `url` | `string` | `""` | URL or file path to load in the webview. |

## Window Events

Windows emit events through the [Events](events.md) system. Subscribe using `Events.on()` with a `WindowEvent` value.

### Events with size/position payload

These events provide a `WindowSizeEventPayload`:

| Event | Description |
|-------|-------------|
| `WindowEvent.RESIZE` | The window was resized. |
| `WindowEvent.MOVE` | The window was moved. |

```typescript
interface WindowSizeEventPayload {
  windowId: number;
  width: number;
  height: number;
  x: number;
  y: number;
}
```

### Events with base payload

These events provide a `WindowEventPayload`:

| Event | Description |
|-------|-------------|
| `WindowEvent.CLOSE_REQUESTED` | The user clicked the close button. Call `event.preventDefault()` to cancel. |
| `WindowEvent.CLOSED` | The window was closed and resources released. |
| `WindowEvent.FOCUS` | The window gained focus. |
| `WindowEvent.BLUR` | The window lost focus. |
| `WindowEvent.MINIMIZE` | The window was minimized. |
| `WindowEvent.MAXIMIZE` | The window was maximized. |
| `WindowEvent.RESTORE` | The window was restored from minimized or maximized state. |
| `WindowEvent.ENTER_FULLSCREEN` | The window entered fullscreen. |
| `WindowEvent.EXIT_FULLSCREEN` | The window exited fullscreen. |

```typescript
interface WindowEventPayload {
  windowId: number;
}
```

## Examples

### Creating a window

```typescript
import { Window } from "@zapp/runtime";

const win = Window.create({
  title: "My App",
  width: 1024,
  height: 768,
  minWidth: 400,
  minHeight: 300,
  url: "views/main.html",
});
```

### Listening for resize events

```typescript
import { Events, WindowEvent } from "@zapp/runtime";

Events.on(WindowEvent.RESIZE, (event) => {
  // event is typed as WindowSizeEventPayload
  console.log(`Window ${event.windowId} resized to ${event.width}x${event.height}`);
});
```

### Preventing window close

Use `CLOSE_REQUESTED` to intercept the close action, and `destroy()` to force-close when ready.

```typescript
import { Events, Window, WindowEvent } from "@zapp/runtime";

Events.on(WindowEvent.CLOSE_REQUESTED, (event) => {
  event.preventDefault();

  const confirmed = await showConfirmDialog("Unsaved changes. Close anyway?");
  if (confirmed) {
    Window.current().destroy();
  }
});
```

### Hidden window shown later

```typescript
const splash = Window.create({
  title: "Loading...",
  width: 400,
  height: 300,
  visible: false,
  decorations: false,
});

// Show after initialization
splash.show();
```

## Worker Context

- `Window.current()` **throws** when called from a worker, because workers are not associated with any window.
- `Window.create()` works from any context, including workers. The returned `WindowHandle` is fully functional.
