# Zapp Benchmarks

## Quick Run

```bash
# Full benchmark (binary size + startup + memory)
./benchmarks/bench.sh

# Bridge performance (run from webview console)
# Copy benchmarks/bridge-bench.ts content into the dev tools console
```

## What We Measure

### Binary Size
Release build with `--brotli`, measured in bytes. Zapp's 210 KB binary is 20-1400x smaller than competitors.

### Startup Time
Cold launch to process running, 10 iterations, median reported. Uses wall clock from `fork` to process exit (kill after 0.5s).

### Memory (RSS)
Resident Set Size after 1 second of idle, measured via `ps -o rss=`.

### Bridge Throughput
Round-trip time for JS → Native → JS service calls. Measures `Services.invoke()` latency and `Events.emit()` throughput.

## Competitive Reference

| Metric | Zapp | Tauri v2 | Wails v3 | Electron | Electrobun |
|--------|------|----------|----------|----------|-----------|
| Binary | ~210 KB | 5-15 MB | 4-8 MB | 100-300 MB | ~14 MB |
| Startup | TBD | <500 ms | <200 ms | 1-2 s | <50 ms |
| Idle RAM | TBD | 30-40 MB | Low | 200-300 MB | TBD |
| IPC latency | TBD | ~0.05-0.2 ms | ~0.1-0.3 ms | ~0.1-0.5 ms | TBD |

## Security Posture

### What Zapp does today
- **CSP**: Injected via meta tag (`default-src 'self'; script-src 'self'`)
- **COOP/COEP/CORP**: `same-origin` on all asset responses (enables SharedArrayBuffer)
- **Custom scheme**: `zapp://` isolates from web origins
- **Bounded buffers**: Uses `snprintf`/`strncpy` (154 uses, 0 unbounded `sprintf`)
- **Worker isolation**: Workers run in separate JS contexts (QJS/JSC), no DOM access
- **Context guards**: `Window.current()` and `Dialog.*` throw in worker context

### Hardening opportunities
- [ ] **Validate bridge messages**: `parse_wire()` doesn't validate format — malformed messages silently misbehave
- [ ] **Service capability enforcement**: Capabilities are checked but the system has no built-in capability token generation
- [ ] **Navigation restrictions**: No `will-navigate` handler to prevent webview navigating away from app
- [ ] **File dialog path validation**: Returned paths aren't sanitized — app code must validate
- [ ] **Configurable CSP**: CSP is hardcoded in bootstrap; should be configurable via `zapp.config.ts`
- [ ] **Disable dev tools in production**: `webContentInspectable` defaults to `true`
- [ ] **Permissions API**: No Tauri-style granular permissions for native APIs (file system, shell, etc.)
