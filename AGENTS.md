# Goal

The goal of this project (Zapp) is to create an alternative to Wails (v3alpha.wails.io), Electron, and Tauri. I explored the desired api and functionality in `./context.md`. Always refer to `./context.md` when building out features.

# Language

I want to use Zen-C which can work with C, C++, and Objective-C. Refer to `./Zen-C.md` for the language reference. Always refer to this doc when you hit a syntax or compilation error to ensure you are following language semantics.

The Zen-C standard lib is here: https://github.com/z-libs/Zen-C/blob/main/docs/std/README.md

# Setup

In `./example` we want to build a test app, like what an end user would do. So I created a sample with a vite/svelte template in the `frontend` directory. `./example/zapp/app.zc` is how users will consume and run our framework.

`./src` is where the framework code will live. We support macOS and Windows.

# Progress

## Logging System (Completed)

- Unified logging module: `src/platform/shared/log.zc`
- Log levels: error, warn, info, debug, trace
- ANSI color support (red, yellow, cyan, gray)
- Per-window sequential worker IDs
- Default log levels: info (dev), warn (prod)
- CLI flags: `--log-level`, `--debug`
- Asset embedding default for `zapp build`
- Binary size optimization with `-Oz` flag

## Bootstrap Scripts

- `bootstrap.sh` (macOS/Linux) - Syncs native code to CLI and rebuilds CLI
- `bootstrap.ps1` (Windows) - Same for Windows
- Usage: `./bootstrap.sh` or `./bootstrap.sh --clean` (also cleans build artifacts)

## Window Events System (Completed - macOS & Windows)

### Event Type Definitions (`src/event/events.zc`)
- Struct-based compile-time constants via `def` for dot-access syntax
- `WindowEvent.READY`, `WindowEvent.FOCUS`, `WindowEvent.BLUR`, etc.
- `AppEvent.STARTED`, `AppEvent.SHUTDOWN`
- Dual-layer: `def` structs for Zen-C user code, `#define` macros (with `#ifndef` guards) for C `raw {}` blocks

### Native API (`src/platform/window.zc`)
- `win.on(WindowEvent.FOCUS, callback)` — register event callbacks (no app pointer needed)
- `win.on_ready(callback)` — register ready callback (calls `zapp_window_set_on_ready` directly)
- Callbacks stored in static arrays indexed by numeric window ID
- `zapp_window_trigger_event(id, event_id)` fires native callbacks from platform code

### macOS Native (`src/platform/darwin/window.zc`)
- `windowDidBecomeKey:` delegate → focus event (native callback + JS bridge)
- `windowDidResignKey:` delegate → blur event (native callback + JS bridge)
- `bridgeReady` / `pendingFocusEvent` buffering on `ZappWindowDelegate`
- `zapp_dispatch_window_event_to_bridge()` injects JS into all webviews

### Windows Native (`src/platform/windows/platform.zc`, `window.zc`)
- `WM_ACTIVATE` handler in `ZappWindowProc` → focus/blur events
- `zapp_win_id_for_hwnd()` reverse lookup (HWND → string window ID)
- `zapp_dispatch_window_event_to_bridge_win()` injects JS into all webviews
- `bridgeReady` / `pendingFocusEvent` buffering on `ZappWindowEntry`
- Bridge-ready wiring in "ready" message handler replays buffered focus
- Native windows registered in `zapp_win_reg` via `windows_window_register_numeric_id`

### TypeScript Runtime (`packages/runtime/events.ts`, `windows.ts`)
- `WindowEvent` enum: READY, FOCUS, BLUR, RESIZE, MOVE, CLOSE, MINIMIZE, MAXIMIZE, RESTORE, FULLSCREEN, UNFULLSCREEN
- `AppEvent` enum: STARTED, SHUTDOWN
- `Events.on()`, `Events.once()`, `Events.off()`, `Events.offAll()`
- `Window.current().on(WindowEvent.FOCUS, handler)` with typed payloads
- `WindowEvent.READY` handlers fire immediately if window already ready

### Bootstrap Runtime (`packages/bootstrap/src/webview.ts`, `webview_windows.ts`)
- Unified listener storage via `Symbol.for("zapp.bridge")._listeners`
- `dispatchWindowEvent()` fires both legacy and global event formats
- `deliverEvent()` handles `once` listeners (removes after firing)

### Event Flow
```
macOS:  NSWindow Delegate → zapp_window_trigger_event() + zapp_dispatch_window_event_to_bridge()
Windows: WM_ACTIVATE      → zapp_window_trigger_event() + zapp_dispatch_window_event_to_bridge_win()
  → JavaScript bridge.dispatchWindowEvent(windowId, eventName)
  → Internal listeners fire (window:focus, window:blur)
  → Typed listeners filter by windowId and fire
```

### Usage Example (Zen-C Backend)
```zc
fn on_focus() -> void { println "[native] focused!"; }
fn on_blur() -> void { println "[native] blurred!"; }
fn on_ready() -> void { println "[native] ready!"; }

let win = app.window.create(&opts);
win.on_ready(on_ready);
win.on(WindowEvent.FOCUS, on_focus);
win.on(WindowEvent.BLUR, on_blur);
```

### Usage Example (TypeScript Frontend)
```typescript
import { Window, WindowEvent } from '@zapp/runtime';

const offFocus = Window.current().on(WindowEvent.FOCUS, (payload) => {
    console.log('Window focused:', payload.windowId);
});

Window.current().once(WindowEvent.READY, () => {
    console.log('Window ready!');
});

offFocus(); // cleanup
```

## Discoveries

1. **Zen-C `def` with structs**: `def` supports struct literals with plain values, enabling `WindowEvent.FOCUS` dot-access syntax. Does NOT work with C `#define` macros inside the literal — use integer literals only.

2. **Zen-C `def` vs `#define`**: `def` constants are not available inside `raw {}` blocks. Use C `#define` (with `#ifndef` guards) for raw block consumption.

3. **Zen-C raw block emission ordering**: When multiple `.zc` files compile into one `.c` file, `raw {}` block order follows the import tree (depth-first). Use `#ifndef` guards for `#define` macros and `#ifndef` guards for struct definitions (`ZAPP_WINDOW_ENTRY_DEFINED` pattern) to be safe against any emission order.

4. **Cross-file struct sharing**: Anonymous struct typedefs (`typedef struct { ... } Foo;`) cannot be forward-declared. Always use tagged structs (`typedef struct Foo { ... } Foo;`) for types referenced across files. Wrap definitions in `#ifndef` include guards when the defining file may be emitted after the consuming file.

5. **Zen-C raw block parsing**: Zen-C parses content inside `raw {}` blocks. Use separate `raw {}` blocks with `#ifdef` at the top level for platform-specific code.

6. **Binary size optimization**: 
   - `-Oz` flag: aggressive size optimization
   - `-flto`: link-time optimization
   - `strip`: removes debug symbols
   - **JSC**: ~200KB (uses system JavaScriptCore framework)
   - **QJS**: ~745KB (embeds QuickJS runtime)

## Phase 2 (Later)

- [ ] File logging support
- [ ] Multi-window IPC between windows
- [ ] Explore trait-based worker engine abstraction (Option C)
- [ ] Cancellable window events (close prevention)
- [ ] Additional window events (resize, move, minimize, maximize, restore, fullscreen)
- [ ] App events (started, shutdown)