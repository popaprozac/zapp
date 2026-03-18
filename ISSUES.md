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

### Window Event Listeners (Like Wails)

**Reference:** https://v3alpha.wails.io/reference/window/#window-events

**Current:** Single `on_ready` callback per window

**Future:** Add event listener API for windows:
- `window.on("ready", callback)`
- `window.on("close", callback)`
- `window.on("focus", callback)`
- `window.on("blur", callback)`
- etc.

This would allow multiple listeners per event type, similar to Wails.

---

## on_ready Callback Design

**Current Design:**
- Single callback per window (not multiple listeners)
- Settable from:
  - Native Zen-C: `win.on_ready(&app.window, callback)`
  - TypeScript: `Window.onReady(windowId, callback)` via bridge

**Callback Storage:** Static array indexed by numeric window ID:
```c
#define ZAPP_MAX_WINDOW_CALLBACKS 64
static void (*zapp_window_on_ready_cbs[ZAPP_MAX_WINDOW_CALLBACKS])(void) = {0};
```

**Setting a callback replaces any previous callback for that window.**

---

## webContentInspectable Defaults

**Implemented:**
- Dev mode: `true` (inspectable by default)
- Prod mode: `false` (not inspectable by default)
- User can override via `AppConfig` in native code or `App.configure()` in TypeScript

**Usage in native code:**
```zc
let config = AppConfig{ 
    name: "My App",
    webContentInspectable: app_get_default_web_content_inspectable(), // Use build default
    ...
};
```

**Usage in TypeScript:**
```typescript
App.configure({
    name: "My App",
    // webContentInspectable not set = uses build default
});
```
