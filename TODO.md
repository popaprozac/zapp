# Zapp TODO List

## Phase 1 (Do Now)

### 1. Memory Management Fixes
- [ ] Fix memory leaks in `app_apply_configure` (Windows) - manual malloc needs free
- [ ] Fix memory leak in macOS `strdup` in app.zc:250
- [ ] Use proper memory patterns: defer for Zen-C, manual free for raw blocks

### 2. Service Error Handling (Wails-style Traits)
- [ ] Refactor service.zc to use traits for lifecycle
- [ ] Add ServiceStartup, ServiceShutdown interfaces
- [ ] Use Result types for error handling
- [ ] Return proper error JSON instead of "{{}}"

### 3. Use Zen-C std/json.zc
- [ ] Replace manual JSON parsing in `app_apply_configure` (Windows)
- [ ] Replace manual JSON parsing in `app_invoke_rpc`
- [ ] Ensure JSON lib is included in bootstrap compilation

### 4. Linux Build-Time Error
- [x] Add compile_error for Linux in platform.zc
- [x] Fail at build time, not runtime

### 5. window.zappReady
- [x] Implement zapp-ready event in bootstrap
- [x] Fire when window content loads
- [x] Export to @zapp/runtime

### 6. Auto-generate Bindings
- [x] Wire generate.ts to dev script
- [x] Wire generate.ts to build script
- [ ] Consider file watching for auto-regeneration

### 7. @zapp/backend Package Guarding
- [x] Add runtime check for backend context
- [x] Throw error if loaded in worker context

### 8. Content Security Policy
- [x] Inject CSP meta tag in webview
- [x] Or set via WKWebView configuration

---

## Phase 2 (Later)

- [x] Add logging system (unified, colored, log levels)
- [x] Windows log conversion (fixed with separate raw blocks)
- [ ] File logging support (backlog)
- [ ] Multi-window IPC between windows
- [ ] Explore trait-based worker engine abstraction (Option C)
- [x] Window Events Phase 1 (focus, blur with typed API)
- [ ] Cancellable window events (close prevention)
- [ ] Additional window events (resize, move, minimize, maximize, restore, fullscreen)
- [ ] App events (started, shutdown)

---

## Open Questions

- [ ] Can we use traits+opaque structs to unify JSC/QJS engine selection?
- [ ] TODO: Explore Option C for worker engine unification
