# Known Issues

## macOS Issues (Fix on macOS Device)

### 1. on_ready Double-Fire Bug

**Location:** `src/platform/darwin/webview.zc` lines 513-519

**Problem:** macOS has TWO ready message senders:
- Native `WKUserScript` that listens for `DOMContentLoaded` and posts `window\nready\n{...}`
- TypeScript `fireReady()` in `packages/bootstrap/src/webview.ts` that does the same

This causes:
- Duplicate message processing
- `zapp_backend_dispatch_window_ready()` called twice
- `window_manager_trigger_on_ready()` called twice
- User callbacks fire twice

**Fix:** Remove the native `WKUserScript` ready script from `webview.zc` and rely solely on TypeScript `fireReady()` (which has a `readyFired` guard).

**Code to remove:**
```objc
// src/platform/darwin/webview.zc lines 513-519
NSString* readyScript = @"document.addEventListener('DOMContentLoaded', function() { ... });";
WKUserScript* readyUserScript = [[WKUserScript alloc]
    initWithSource:readyScript
    injectionTime:WKUserScriptInjectionTimeAtDocumentStart
    forMainFrameOnly:NO];
[ucc addUserScript:readyUserScript];
```

---

### 2. webContentInspectable Not Applied to WebView2 (Windows Only) - FIXED

**Location:** `src/platform/windows/webview.zc` line 835

**Problem:** The `inspectable` parameter is ignored:
```c
void zapp_windows_webview_create(HWND hwnd, BOOL inspectable, const char* windowId) {
    (void)inspectable;  // <-- IGNORED!
```

**Fix:** Implement WebView2 dev tools control using `ICoreWebView2_2->OpenDevToolsWindow()` or controller settings.

**Status:** Partially fixed - defaults now work (true for dev, false for prod). WebView2-specific dev tools control still needs implementation.

---

## Completed Optimizations (Windows)

### 1. O(1) Window ID Lookup

**Before:** Linear scan through 256-element array for string ID lookup
**After:** Hash table with O(1) average lookup using DJB2 hash

**Files changed:**
- `src/platform/windows/window.zc` - `zapp_win_lookup()` now uses hash table

### 2. O(1) HWND → Numeric ID Lookup

**Before:** Linear scan through 64-element array
**After:** Hash table with O(1) average lookup using lower bits of HWND

**Files changed:**
- `src/platform/windows/window.zc` - `zapp_numeric_id_for_hwnd()` now uses hash table

---

## Future Enhancements

### Additional Window Events
- [ ] resize, move, minimize, maximize, restore, fullscreen, unfullscreen
- [ ] Extend `zapp_get_window_event_name_win()` (Windows) and macOS `zapp_dispatch_window_event_to_bridge()` switch cases
- [ ] Cancellable events (e.g. close prevention)

### App Events
- [ ] `AppEvent.STARTED`, `AppEvent.SHUTDOWN` (constants already defined in `events.zc`)

---

## Completed: Window Event System

**Implemented (macOS & Windows):**
- `win.on(WindowEvent.FOCUS, callback)` — no app pointer needed
- `win.on_ready(callback)` — fires when webview bridge is ready
- Single callback per event per window, stored in static arrays
- Focus/blur events dispatch to both native callbacks and JS bridge
- `bridgeReady` + `pendingFocusEvent` buffering for events arriving before JS is loaded

**Callback Storage:** Static arrays indexed by numeric window ID:
```c
#define ZAPP_MAX_WINDOW_CALLBACKS 64
static void (*zapp_window_event_cbs[ZAPP_MAX_WINDOW_CALLBACKS][ZAPP_MAX_WINDOW_EVENT_TYPES])(void) = {{0}};
static void (*zapp_window_on_ready_cbs[ZAPP_MAX_WINDOW_CALLBACKS])(void) = {0};
```

---

## webContentInspectable Defaults

**Implemented:**
- Dev mode: `true` (inspectable by default)
- Prod mode: `false` (not inspectable by default)
- User can override via `AppConfig` in native code or `App.configure()` in TypeScript

---

## Cross-Platform Compilation Notes

### Zen-C raw block ordering
When `.zc` files compile into one `.c` file, `raw {}` blocks are emitted in import-tree depth-first order. This causes issues when a type or macro is used in a file that's emitted before the file that defines it.

**Patterns to follow:**
- `#define` macros: always wrap in `#ifndef` guards
- Struct typedefs shared across files: use tagged structs (`typedef struct Foo { ... } Foo;`) and wrap in `#ifndef DEFINED` guards
- Example: `ZappWindowEntry` is defined in `window.zc` (emitted first) with `#ifndef ZAPP_WINDOW_ENTRY_DEFINED`, and the same guard skips the duplicate in `webview.zc` (emitted later)
