# Embeddable webviews (`<zapp-webview>`) — design

**Date:** 2026-06-05
**Branch:** `feat/embed-webview`
**Surfaced by:** the competitive strategic plan (`~/.claude/plans/polished-mapping-ullman.md`, Q2 / Tier-3 "nested webviews"). Its trigger condition fired: **Wails shipped their version** (PR #4880, "WebviewPanel"). User wants a Zapp equivalent that "feels like an iframe but more powerful — it's a full webview."

## What Wails #4880 actually shipped (reference, for the record)

Wails' `WebviewPanel` is **absolute window-coordinate panels**, NOT a DOM-tracked element. `window.NewPanel({Name, X, Y, Width, Height, URL, HTML, ZIndex, Visible, ...})` creates a separate native webview (macOS = a `WKWebView` subview of the window `contentView`; Windows = child WebView2; Linux = WebKit2GTK in GtkFixed) positioned by absolute coords with `DockLeft/DockRight/FillWindow` helpers. Methods: `SetBounds/SetURL/SetHTML/ExecJS/Show/Hide/SetZoom/Destroy`. No per-panel process isolation (shares window IPC). iOS/Android stubbed. Documented limits: Linux z-index no-op, macOS can't programmatically open DevTools, frameless/anchor unimplemented.

**Zapp departs from Wails on the positioning model** (DOM-tracked element, below) because the user's goal is iframe ergonomics, which absolute coords don't deliver. The native primitive underneath is the same idea (a child webview at `{x,y,w,h}`).

## The core decision — positioning model

**DOM-rect-tracked custom element (Electrobun OOPIF shape), NOT absolute coords.** Rationale: "feels like an iframe" *is* the DOM-tracked model — the embed must live in the document and move with layout/scroll. Absolute coords (Wails) explicitly don't feel like an iframe.

### What it buys vs a real iframe (the "more powerful")
- **No `X-Frame-Options` / `frame-ancestors` blocking** — a native webview is a top-level browsing context, so it embeds *any* site (Notion, Google, GitHub, banks) that a real iframe cannot. This is the killer property and the reason to build it.
- Own process, own cookie/session jar, heavy content without janking the app UI thread, native-controlled navigation + script injection.

### The leaks (every OOPIF impl has these — Electrobun, Electron `<webview>`, Tauri)
1. **Scroll swim** — the native webview is a separate OS compositing layer; the rect update lands a frame or two behind the page on fast/momentum scroll.
2. **Flat z-order** — the native webview always sits *above* the host webview; app DOM (modals, dropdowns, tooltips) can't render over it.
3. **Clip/rounding/transform** — it's a rectangular OS layer; `overflow:hidden` ancestors, `border-radius`, CSS `transform` won't naturally clip/follow it.

**v1 documents these; it does not solve them.** Mitigation (clip masks, modal-aware z-lowering, scroll pinning) is a deliberately separate follow-up effort (user's call).

## Rect tracking — reflow-free (the pretext lesson)

The expensive/janky pattern is calling `getBoundingClientRect()` in a `scroll`/`resize` handler every frame — it forces synchronous layout. We avoid it.

- **Chosen approach:** an **IntersectionObserver (re-armed with tight `rootMargin`s) + ResizeObserver**. An IO entry already carries `entry.boundingClientRect` + `entry.rootBounds`, computed by the browser during *its own* render pass — reading them in the callback does not force an extra reflow, and we avoid a per-scroll-tick handler. `getBoundingClientRect()` is used only for the initial paint and as a fallback.
- **pretext citation** (`github.com/chenglou/pretext`): the user raised it. Pretext is a *text-measurement* library that avoids reflow via canvas `measureText()` + arithmetic. Its *specific* technique does **not** transfer — element screen-position in an arbitrary live DOM (flexbox/grid/scroll/transforms) cannot be precomputed by arithmetic; it must be read from the browser. But its *principle* ("never trigger forced synchronous layout/reflow") is exactly why we use observers over a gBCR poller. Cited in docs as the "why reflow-free" rationale.
- **Honesty caveat:** reflow-free tracking removes the *reflow cost* and handler overhead. It does **not** remove the two-layer compositing lag (leak #1) — that remains for the separate mitigation effort. Watch (future): CSS `anchor-positioning` / scroll-driven timelines as a newer angle.

## API surface

The custom element *is* the handle (most iframe-like):
```html
<zapp-webview src="https://notion.so" id="side"></zapp-webview>
```
```ts
const v = document.querySelector("zapp-webview") as ZappWebviewElement;
await v.loadURL(url);
await v.execJS(code);           // host -> embed: run JS in the embed
v.postMessage(data);            // host -> embed: structured message
v.on("did-navigate" | "title-change" | "load-finished" | "load-failed" | "message", cb);
v.reload(); v.goBack(); v.goForward(); v.destroy();

// programmatic (non-markup) construction:
const v2 = Webview.create({ src, bridge?: false, partition?: string });
```
- **Attributes:** `src` (URL); `bridge` (boolean, opt-in, app-origin only — see Security); `partition` (named session store).
- **Events** (on the element): `did-navigate` (url), `title-change` (title), `load-finished`, `load-failed` (url, code, desc), `message` (data from the embed).
- **Host↔embed messaging:** every embed (even sandboxed) gets a *minimal injected shim* — `window.zappHost.postMessage(data)` (embed→host, surfaces as the element's `"message"` event). Host→embed via `execJS`/`postMessage`. This shim is NOT the bridge: no Services, no `__zappBridge`, no C calls.
- **API name:** `Webview` (the element tag `zapp-webview`; the programmatic factory `Webview.create`).

**Rejected alternative — imperative-primary** (`Window.embedWebview({bounds,url})`, app positions it): closer to Wails, but loses the iframe feel. The element is primary; `Webview.create()` is the thin imperative escape hatch (it inserts/returns an element).

## Security & sessions

- **External origin** (`https://…`): **sandboxed** — only the postMessage shim, never `__zappBridge`/Services/host objects. You must never hand a remote site the native C-call bridge.
- **App origin** (`zapp://` / bundled assets) **+ explicit `bridge` attribute**: **full bridge** opt-in (the same injection the main webview gets).
- **Session/data store:** default = the app's shared persistent `WKWebsiteDataStore` (so "log into embedded Notion once" persists across embeds + launches). `partition="name"` → isolated named persistent store. v1 ships shared-default + named `partition`. Ephemeral/incognito partitions deferred.

## Native-first chain & scope

Standard chain (C primitive → Zen-C → router → TS runtime → docs):
- **C primitives** (`native/platform/darwin/webview.m`, reusing its existing `WKWebViewConfiguration`/`zapp://` scheme/bootstrap/eval machinery): `darwin_panel_create(window_id, panel_id, url, bridge, partition)`, `darwin_panel_set_bounds(panel_id, x, y, w, h)`, `darwin_panel_load_url`, `darwin_panel_eval_js`, `darwin_panel_post_message`, `darwin_panel_show/hide`, `darwin_panel_reload/back/forward`, `darwin_panel_destroy`. The panel `WKWebView` attaches as a subview of the host window's `contentView` (`native/platform/darwin/window.m`).
- **Zen-C:** a `native/panel/panel.zc` manager (panel registry keyed by id, owning window) + router routes (`__panel:create`, `__panel:setBounds`, `__panel:loadUrl`, `__panel:execJs`, `__panel:postMessage`, `__panel:destroy`, …) wired in `native/app/router.zc` alongside the existing `__window:*` routes. Navigation/title/load events flow back via the existing event→webview dispatch (the same path `darwin_window_eval_js` uses).
- **TS runtime:** a new `runtime/webview.ts` — the `ZappWebviewElement` custom element (definition + lifecycle + the reflow-free tracking layer + coordinate conversion) and the `Webview` factory. Runs in the webview/runtime context (not workers). Exported from `runtime/index.ts`.
- **Docs:** `docs/api-reference.md` (the `Webview` element + API), plus a short "Embedded webviews" concept note covering the three leaks + the sandbox/bridge model + session partitions.

**Platform:** **macOS-first.** iOS + Windows get inert no-op stubs so shared `.zc` (router/panel manager compiled into every target) links — the recurring iOS-parity rule (`#ifdef __APPLE__` is true on iOS; every `darwin_*` called from shared `.zc` needs an iOS def). Real iOS/Windows impls deferred.

## Coordinate & lifecycle details (for the plan)

- **Coordinate conversion:** CSS px (top-left origin, device-independent) → window points → macOS bottom-left origin. Account for `devicePixelRatio`/backing scale and the window's title-bar/content inset. The native side receives content-view-relative points.
- **Lifecycle:** element `connectedCallback` → `__panel:create` (hidden) → first rect → `setBounds` + `show`. `disconnectedCallback` → `__panel:destroy`. `src` attribute change → `loadURL`. Element hidden (`display:none`/0-area rect) → `hide` the native panel (don't destroy).
- **One window, N panels:** the panel registry is per-window; closing a window destroys its panels.

## Verification

- `bun run check` + `bun run test:all` stay green (new TS gets a tsc pass; pure-logic helpers — coordinate conversion, rect diffing — get `bun:test` units).
- macOS `bun run build` → `[zapp] build complete:`; ios-simulator build links (stubs present) → `[zapp] build complete:`.
- Manual smoke (hello-world): a `<zapp-webview src="https://example.com">` in normal flow renders the live site, tracks on scroll/resize, `load-finished` fires, host `execJS`/`postMessage` round-trips, `destroy` removes it. An external embed has NO `__zappBridge`; an app-origin `bridge` embed does.

## Non-goals (v1)

- **Leak mitigations** — scroll-pinning, clip masks for `overflow`/`border-radius`, modal-aware z-lowering. Separate follow-up.
- **Windows / Linux / iOS real implementations** — stubs only.
- **Ephemeral/incognito partitions**, per-embed proxy, **programmatic DevTools-open** (macOS lacks a public API — same limit Wails documented).
- **App-origin bridge *injection*** (`bridge` attribute making `__zappBridge`/Services work *inside* a panel) — **deferred to a follow-up** during planning. The `bridge` + `partition` attributes are plumbed end-to-end (API + `darwin_panel_create` signature) but are **inert in v1**: every embed is sandboxed, shared default `WKWebsiteDataStore`. Reason: panel↔bridge invoke-response routing would balloon v1, and the killer value (embedding external sites) is entirely in the sandboxed path. Forward-compatible — adding injection later is non-breaking.
- **CSS transform following** (rotate/scale/3D) — flat rect only.
- **Pre-render/pooling** of panels for instant show — later perf work.

## Related

- `~/.claude/plans/polished-mapping-ullman.md` Q2 / Tier-3 — the strategic trigger.
- [[reference_ios_symbol_parity_gate]] + [[project_background_app_readiness_cycle]] — the `#ifdef __APPLE__`/iOS-stub rule that makes the panel manager need iOS stubs.
- [[feedback_native_first_implementation]] — the C → Zen-C → router → TS → docs chain this follows.
- [[project_testing_infrastructure_cycle]] — `bun run check` + `test:all` gate the new TS.
