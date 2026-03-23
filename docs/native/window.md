# Window (Native)

Native window management in Zen-C.

## WindowOptions

```zc
struct WindowOptions {
    title: string;
    width: int;
    height: int;
    x: int;                     // 0 = centered
    y: int;                     // 0 = centered
    visible: bool;
    resizable: bool;
    closable: bool;
    minimizable: bool;
    maximizable: bool;
    fullscreen: bool;
    borderless: bool;
    transparent: bool;
    hidden: bool;
    alwaysOnTop: bool;
    titleBarStyle: TitleBarStyle;
    webContentInspectable: int; // -1 = inherit, 0 = off, 1 = on
}
```

Use `window_options_default(title)` for sensible defaults (1200x800, all options enabled).

## Window Struct

```zc
struct Window {
    id: int;
    handle: void*;
}
```

### Methods

| Method | Return | Description |
|---|---|---|
| `on(event_id, cb)` | `void` | Register event callback. `cb: fn*(WindowEventData*) -> int` |
| `on_ready(cb)` | `void` | Register ready callback. `cb: fn*(int, void*) -> void` |
| `show()` | `void` | Make window visible |
| `hide()` | `void` | Hide window |
| `minimize()` / `unminimize()` | `void` | Minimize/restore |
| `maximize()` / `unmaximize()` | `void` | Maximize/restore |
| `toggle_minimize()` / `toggle_maximize()` | `void` | Toggle state |
| `close()` | `void` | Normal close (triggers guards) |
| `destroy()` | `void` | Force close (bypasses guards) |
| `size()` | `WindowSize` | Current width/height |
| `position()` | `WindowPosition` | Current x/y |
| `is_minimized()` | `bool` | Check state |
| `is_maximized()` | `bool` | Check state |
| `is_fullscreen()` | `bool` | Check state |

## WindowEventData

Event callbacks receive a pointer to this struct:

```zc
// Defined in raw C for cross-platform compatibility
typedef struct WindowEventData {
    int32_t event;   // WindowEvent ID
    int32_t width;   // Populated for RESIZE, MOVE, MAXIMIZE, RESTORE
    int32_t height;
    int32_t x;
    int32_t y;
} WindowEventData;
```

Callbacks return `int`: `0` = ALLOW, `1` = CANCEL (only meaningful for CLOSE).

## Example

```zc
fn on_ready(id: int, handle: void*) -> void {
    let win = Window{id: id, handle: handle};
    win.show();
}

fn on_resize(data: WindowEventData*) -> int {
    raw {
        printf("resized to %dx%d\n", data->width, data->height);
    }
    return 0;
}

fn on_close(data: WindowEventData*) -> int {
    let _d = data;
    // Return 1 to prevent close
    return 0; // allow
}

// In run_app():
let opts = window_options_default("My App");
opts.width = 800;
opts.height = 600;
opts.visible = false;
let win = app.window.create(&opts);
win.on_ready(on_ready);
win.on(WindowEvent.RESIZE, on_resize);
win.on(WindowEvent.CLOSE, on_close);
```

## Window Events

| Event | ID | Data fields |
|---|---|---|
| `READY` | 0 | — |
| `FOCUS` | 1 | — |
| `BLUR` | 2 | — |
| `RESIZE` | 3 | width, height, x, y |
| `MOVE` | 4 | width, height, x, y |
| `CLOSE` | 5 | — (return value matters) |
| `MINIMIZE` | 6 | — |
| `MAXIMIZE` | 7 | width, height, x, y |
| `RESTORE` | 8 | width, height, x, y |
| `FULLSCREEN` | 9 | — |
| `UNFULLSCREEN` | 10 | — |
