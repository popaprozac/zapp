# Security

Zapp includes several security mechanisms to protect desktop apps from common web-based attacks.

## Content Security Policy (CSP)

Zapp injects a CSP meta tag into every webview on both platforms.

**Default policy (strict):**
```
default-src 'self';
script-src 'self';
style-src 'self' 'unsafe-inline';
connect-src 'self';
img-src 'self' data: blob:;
```

**Custom CSP** — configure in `zapp.config.ts`:
```ts
export default defineConfig({
    security: {
        csp: "default-src 'self'; connect-src 'self' https://api.myapp.com; script-src 'self'",
    },
});
```

If your app needs to fetch from external APIs, add them to `connect-src`.

## Dev Tools

Dev tools (Inspect Element, console, network inspector) are controlled by `webContentInspectable`:

| Build mode | Default | User override |
|---|---|---|
| `zapp dev` | **Enabled** | Can set to `0` (off) in AppConfig |
| `zapp build` | **Disabled** | Can set to `1` (on) in AppConfig |
| `zapp build --debug` | **Enabled** | Can set to `0` (off) in AppConfig |
| `zapp package` | **Disabled** | Can set to `1` (on) in AppConfig |

In Zen-C:
```zc
let config = AppConfig{
    webContentInspectable: -1, // -1 = inherit from build mode
                               //  0 = always off
                               //  1 = always on
};
```

Per-window override via `WindowOptions.webContentInspectable` (`-1`/`0`/`1`).

## Path Traversal Prevention

The `zapp://` custom scheme handler rejects any URL containing `..` sequences with a 403 Forbidden response. This prevents attempts to access files outside the app's asset directory.

## Cross-Origin Headers

All asset responses include strict cross-origin headers:
```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
Cross-Origin-Resource-Policy: same-origin
Cache-Control: no-cache
```

These prevent cross-origin resource theft and enable `SharedArrayBuffer` in contexts where it's supported.

## Context Menu Filtering

The default right-click context menu is filtered to remove browser-specific items (Reload, Back, Forward). Text editing items (Copy, Cut, Paste, Select All) are preserved.

## Worker Context Guards

APIs that don't make sense in worker contexts throw clear errors:
- `Window.current()` — throws in workers (use `Window.create()` instead)
- `Dialog.*` — throws in workers (dialogs must be shown from the main context)

## Bridge Security

The native bridge uses a simple wire protocol (`type\nkey\npayload`) over `postMessage`. Messages are validated:
- Service method names are restricted to alphanumeric characters, dots, underscores, and hyphens
- Service payload size is limited to 64 KB
- JSON parsing is strict (rejects malformed payloads)

## Recommendations

1. **Don't relax the default CSP** unless you need external API access
2. **Keep `webContentInspectable: -1`** (inherit) — dev tools are off in production automatically
3. **Use `App.openExternal(url)`** for links instead of `window.open()` or navigation
4. **Validate service inputs** in your Zen-C service handlers — the framework validates names and sizes but not business logic
