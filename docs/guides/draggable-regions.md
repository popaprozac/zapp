# Draggable Regions

Custom titlebar apps need a way to let users drag the window. Zapp supports this via the `data-zapp-drag-region` HTML attribute.

## Usage

Add `data-zapp-drag-region` to any element that should act as a drag handle:

```html
<div data-zapp-drag-region class="titlebar">
  <span>My App</span>
  <button>Close</button> <!-- buttons work normally -->
</div>
```

Interactive elements (`<button>`, `<input>`, `<select>`, `<textarea>`, `<a>`) inside a drag region are automatically excluded — clicks on them work normally and don't trigger a drag.

## How it works

1. The bootstrap injects a `mousemove` listener that tracks whether the cursor is over a drag region
2. On macOS: sets a flag on the native `WKWebView` subclass. When `mouseDown:` fires, it calls `performWindowDragWithEvent:` — a synchronous native drag.
3. On Windows: a `mousedown` listener posts a `startDrag` message to native, which calls `ReleaseCapture()` + `SendMessageW(WM_SYSCOMMAND, SC_MOVE | HTCAPTION)`.

## With hidden titlebar

Combine with `titleBarStyle: "hidden"` for a frameless window:

```zc
let opts = window_options_default("My App");
opts.titleBarStyle = WINDOW_TITLEBAR_STYLE_HIDDEN;
opts.visible = false;
let win = app.window.create(&opts);
```

```html
<div data-zapp-drag-region style="height: 40px; -webkit-app-region: drag;">
  <h1 style="margin: 0; padding: 8px 16px; font-size: 14px;">My App</h1>
</div>
```

## Platform notes

| | macOS | Windows |
|---|---|---|
| Mechanism | `performWindowDragWithEvent:` | `WM_SYSCOMMAND + SC_MOVE` |
| Timing | Synchronous (immediate) | Async (via PostMessage) |
| Attribute | `data-zapp-drag-region` | `data-zapp-drag-region` |
