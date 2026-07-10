# Window drag regions & custom title bars

zapp lets web content define which parts of the window drag it, and mark the
window's title bar — with **platform-agnostic markup**. You write the same HTML
on macOS and Windows; the framework bridges each marker to the right native
mechanism per platform.

## The two markers

| Marker | Meaning | Behavior |
|---|---|---|
| `data-zapp-titlebar` | This element **is the window title bar** | Drag the window · double-click to maximize/restore · (Windows) right-click → system window menu |
| `data-zapp-drag-region` (or CSS `--zapp-drag: drag`) | A **custom draggable area** — "grab here to move the window" | Drag only. **No** double-click-maximize |
| — inside a title bar/drag region — | | Interactive elements (`button`, `input`, `select`, `textarea`, `a[href]`, `[role=button]`, `contenteditable`) are automatically excluded (not draggable). Opt an element out explicitly with `--zapp-drag: no-drag`. |

```html
<!-- The window title bar: draggable + double-click maximizes -->
<header data-zapp-titlebar>
  <span>My App</span>
  <button>Settings</button>   <!-- clickable; auto-excluded from drag -->
</header>

<!-- A secondary draggable strip: moves the window, never maximizes -->
<div data-zapp-drag-region>…</div>
```

You do **not** write `-webkit-app-region` in app CSS — the framework injects it
where needed (see below).

## How it maps per platform (the divergence, for the curious)

The *markup is identical*; only the underlying mechanism differs.

| | macOS (WKWebView) | Windows (WebView2) |
|---|---|---|
| **`data-zapp-titlebar`** | JS detects the marker → `NSWindow` drag via `mouseDownCanMoveWindow`; the `ZappWebView` subclass zooms on a native double-click over the title bar | The framework injects `[data-zapp-titlebar]{-webkit-app-region:drag}`; **WebView2's `IsNonClientRegionSupportEnabled`** turns it into a real OS caption region → drag + double-click-maximize + system menu, all native |
| **`data-zapp-drag-region`** | JS `mouseDownCanMoveWindow` (drag only) | JS `beginDrag` gesture (post to native on a >4px move → OS move loop). Drag only |
| **why the split** | WKWebView has no CSS `app-region`, so both go through JS | WebView2 native `app-region` *always* carries dbl-click + menu (Chromium model), so it's used only for title bars; plain drag regions use JS to stay move-only |

Requirements: the native Windows title-bar path needs **WebView2 Runtime
1.0.2420.47+** (`ICoreWebView2Settings9`); the Evergreen runtime is well past
this. Older runtimes fall back gracefully (the CSS is simply ignored — enable the
JS fallback if you must support them).

## CSS metric variables (custom title bars)

For `titleBarStyle: "hidden"`/`"hiddenInset"` windows, the framework exposes the
native caption geometry so web content can lay out around it:

| Variable | Meaning |
|---|---|
| `--zapp-titlebar-height` | Height of the native control cluster — pad the top of your content by this so it isn't hidden under the buttons while still full-bleeding under the bar |
| `--zapp-window-controls-inset-right` | Width of the caption-button cluster (top-right) — reserve this so headers don't collide with min/max/close |
| `--zapp-window-controls-inset-left` | Left inset (macOS traffic-light side); `0` on Windows |

```css
header[data-zapp-titlebar] {
  height: var(--zapp-titlebar-height, 34px);
  padding-right: var(--zapp-window-controls-inset-right, 0);
}
```
