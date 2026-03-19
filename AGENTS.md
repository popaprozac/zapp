# Goal

The goal of this project (Zapp) is to create an alternative to Wails (v3alpha.wails.io), Electron, and Tauri. I explored the desired api and functionality in `./context.md`. Always refer to `./context.md` when building out features.

# Language

I want to use Zen-C which can work with C, C++, and Objective-C. Refer to `./Zen-C.md` for the language reference. Always refer to this doc when you hit a syntax or compilation error to ensure you are following language semantics.

The Zen-C standard lib is here: https://github.com/z-libs/Zen-C/blob/main/docs/std/README.md

# Setup

In `./example` we want to build a test app, like what an end user would do. So I created a sample with a vite/svelte template in the `frontend` directory. `./example/app.zc` is how users will consume and run our framework.

`./src` is where the framework code will live. We are prioritizing and starting with macOS only development with the understanding that we will support Windows in the future.

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

## Windows Log Conversion (Fixed)

- Issue: Zen-C parses content inside `raw {}` blocks even when wrapped in `#ifdef _WIN32`
- Solution: Use separate `raw {}` blocks for each platform, wrapped in `#ifdef` at the top level
- Pattern: `raw { #ifdef _WIN32 ... #endif }` and `raw { #ifndef _WIN32 ... #endif }`

## Discoveries

1. **Zen-C `def` vs `#define`**: Using `def` for constants in Zen-C doesn't make them available inside `raw {}` blocks. Must use C `#define` inside the raw block for use in C code.

2. **Zen-C raw block parsing**: Zen-C parses content inside `raw {}` blocks. Use separate `raw {}` blocks with `#ifdef` at the top level for platform-specific code.

3. **Binary size optimization**: 
   - `-Oz` flag: aggressive size optimization
   - `-flto`: link-time optimization
   - `strip`: removes debug symbols
   - **JSC**: ~200KB (uses system JavaScriptCore framework)
   - **QJS**: ~745KB (embeds QuickJS runtime)

## Bootstrap Scripts

- `bootstrap.sh` (macOS/Linux) - Syncs native code to CLI and rebuilds CLI
- `bootstrap.ps1` (Windows) - Same for Windows
- Usage: `./bootstrap.sh` or `./bootstrap.sh --clean` (also cleans build artifacts)

## Window Events System (Phase 1 - Completed)

### Event Type Definitions (`src/event/events.zc`)
- Numeric event IDs for efficient routing (focus=1, blur=2, etc.)
- Zen-C enums with typed access via `WindowEvent` and `AppEvent` constants

### TypeScript Runtime (`packages/runtime/events.ts`)
- `WindowEvent` enum: READY, FOCUS, BLUR, RESIZE, MOVE, CLOSE, MINIMIZE, MAXIMIZE, RESTORE, FULLSCREEN, UNFULLSCREEN
- `AppEvent` enum: STARTED, SHUTDOWN
- Enhanced EventsAPI: `once()`, `off()`, `offAll()` support
- `WindowEventPayload` interface with windowId, timestamp, size, position

### Window Handle (`packages/runtime/windows.ts`)
- Typed event listeners: `window.on(WindowEvent.FOCUS, handler)`
- One-time listeners: `window.once(WindowEvent.READY, handler)`
- Remove listeners: `window.off(WindowEvent.CLOSE)`
- Legacy string-based events still supported

### Bootstrap Runtime (`packages/bootstrap/src/webview.ts`, `webview_windows.ts`)
- Unified listener storage: Both bootstrap and runtime share `Symbol.for("zapp.bridge")` storage
- Event naming: `"window:ready"`, `"window:focus"`, `"window:blur"` (colon separator)
- `deliverEvent()` properly handles `once` listeners (removes after firing)

### macOS Native (`src/platform/darwin/window.zc`)
- Added `windowDidBecomeKey:` delegate method → emits focus event
- Added `windowDidResignKey:` delegate method → emits blur event
- `zapp_dispatch_window_event_to_bridge()` dispatches to JS via bridge

### Event Flow
```
NSWindow Delegate → zapp_dispatch_window_event_to_bridge()
  → JavaScript bridge.dispatchWindowEvent(windowId, event)
  → Internal listeners fire (window:focus, window:blur)
  → Typed listeners filter by windowId and fire
```

### Key Fix: Unified Listener Storage
- Bootstrap and runtime previously used separate storage locations
- Now both use `Symbol.for("zapp.bridge")._listeners`
- `Events.on()` stores via runtime → bootstrap `_onEvent()` → bridge storage
- `deliverEvent()` reads from bridge storage → both bootstrap and runtime listeners fire

### Usage Example
```typescript
import { Window, WindowEvent } from '@zapp/runtime';

// Listen for focus
const offFocus = Window.current().on(WindowEvent.FOCUS, (payload) => {
    console.log('Window focused:', payload.windowId);
});

// One-time event
const offReady = Window.current().once(WindowEvent.READY, (payload) => {
    console.log('Window ready!');
});

// Cleanup
offFocus();
offReady();

// Or remove all listeners for an event
Window.current().off(WindowEvent.FOCUS);

// Global events
Events.on('window:focus', (payload) => {
    console.log('Any window focused');
});
```

## Phase 2 (Later)

- [ ] Add logging system
- [ ] Windows log conversion (fixed with separate raw blocks)
- [ ] File logging support (backlog)
- [ ] Multi-window IPC between windows
- [ ] Explore trait-based worker engine abstraction (Option C)
- [ ] Cancellable window events (close prevention)
- [ ] Additional window events (resize, move, minimize, maximize, restore, fullscreen)
- [ ] App events (started, shutdown)