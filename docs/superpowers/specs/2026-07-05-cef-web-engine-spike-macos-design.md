# CEF `webEngine:"chromium"` — macOS de-risking spike (design)

**Date:** 2026-07-05
**Branch:** `feat/cef-web-engine` (off `feat/nim-native`)
**Type:** De-risking SPIKE (throwaway-OK code; produces a GO/NO-GO + FINDINGS, not production wiring)
**Status:** design approved (scope A, shape, go/no-go = GO); pending spec review → writing-plans

## Goal

Prove, on macOS (arm64), that **CEF (Chromium Embedded Framework)** can serve as Zapp's opt-in `webEngine:"chromium"` render backend — via the **raw CEF C API integrated into the Nim-native build** — by standing up one real (but minimal) CEF-backed window that exercises every integration seam that matters, and produce a measured GO/NO-GO.

## Why

- **Consistent cross-platform rendering** — the OS WebViews (WKWebView / WebView2 / WebKitGTK) diverge; a bundled Chromium renders identically everywhere. Especially important for **future Linux** (WebKitGTK is the weakest of the three).
- **Competitive parity** — the space is converging on bundled-Chromium opt-ins (zero-native.dev, electrobun's CEF bundling, Deno desktop backends). Table stakes to offer it.
- **Zapp keeps its edge regardless** — **ZJS workers run native, not in the webview**, so the worker differentiation (smallest WinterTC-compat engine + zapp workers) is **render-engine-independent**. CEF only touches the render/webview layer.
- **Size buys back perf/features** — CEF is large (~150–200 MB), so it is **strictly opt-in** (only apps choosing `chromium` pay). In exchange we get concrete wins; **cataloguing those is an explicit deliverable**, not an afterthought. Example #1: **native brotli decode** — today the WKWebView scheme handler must brotli-*decode* embedded assets before serving (an open gap, task #516); CEF can be handed the compressed bytes with `Content-Encoding: br` and decode in Chromium. Others to log: consistent rendering, GPU/compositor pipeline, DevTools protocol.

## Scope decision (approved)

- **Scope:** de-risking spike (not a production backend, not a memo).
- **Approach A:** raw CEF **C API** → Nim `importc` + minimal ObjC for NSView hosting. Rationale: the C API links cleanly into Zapp's C/ObjC/Nim world with **no new C++ toolchain dependency** (aligned with consolidating on Nim + ObjC and removing Zen-C), and it proves the *real* production path. All approaches hit the same #1 risk (message-loop coexistence), so we pay it on the real path.
- **Platform:** macOS arm64 only.

## Reference

**`cefsimple_capi`** (https://github.com/chromiumembedded/cef/tree/master/tests/cefsimple_capi) — the canonical, all-platform **C-API** embedding. It solves the parts that are identical regardless of Zapp and are the highest-risk to get wrong:
- `simple_app.c` — `cef_app_t` (browser-process setup)
- `cefsimple_mac.m` — macOS `NSApplication` entry point
- `process_helper_mac.c` — the macOS **Helper process** bootstrap (the multi-process piece)
- `simple_handler*.c` — the `cef_client_t` split (display / life-span / load handlers)
- `ref_counted.h` — the C-API **manual refcount** pattern every `cef_*_t` embeds (our Nim `importc` wrappers must honor it)

It has **no custom scheme handler and no JS bridge** — precisely the Zapp-specific work the spike adds. We diverge from it in one deliberate place: **host the browser in Zapp's existing `NSWindow`**, not CEF's Views framework (`simple_views.c`).

## What CEF must replace (the WKWebView baseline, `native/platform/darwin/webview.m`)

Custom URL-scheme handler (embedded assets/media) · the `zapp` script-message channel (JS↔native bridge, `WKUserContentController` + `addScriptMessageHandler`) · document-start bootstrap injection · `loadRequest` · navigation delegate · `evaluateJavaScript` (native→JS). CEF has analogs for all; the cost is the multi-process + message-loop model, not the individual APIs.

## Architecture — the spike slice (built in RISK ORDER)

1. **Build + link (gate 0).** Vendor a CEF binary distribution (Spotify automated builds, macos-arm64 `cef_binary_*`). Link `libcef` + the `Chromium Embedded Framework.framework` + the Helper `.app` bundles from a Nim/ObjC build. Nim `importc` the `cef_*_t` struct-of-callbacks + the `ref_counted.h` refcounting. **Separate spike target — not wired into `zapp build`** so the production Nim path stays green. → *proves CEF fits the Nim-native world at all.*
2. **Process model + message loop (gate 1 — THE risk).** Stand up the Helper processes (`process_helper_mac.c` shape) and integrate CEF's loop with `NSApplication`/`CFRunLoop` **and** Zapp's existing ZJS/kqueue loop, via CEF's external message pump / `CefDoMessageLoopWork` (vs CEF-owns-loop). If two run loops can't coexist, everything else is moot. Reference: `cefsimple_mac.m`.
3. **Window hosting.** Put the CEF browser's `NSView` into Zapp's existing `NSWindow` (reuse `window.nim`/`window.m`; swap only the content view for this one window).
4. **Custom scheme handler + brotli probe.** Register a `cef_resource_handler` serving one embedded asset; serve it **brotli-compressed with `Content-Encoding: br`** and confirm Chromium decodes it. Measure.
5. **The `zapp` bridge (one round-trip).** JS→native via CEF's query mechanism (C-API analog of `CefMessageRouter` / a `window.zapp` binding); native→JS via frame `ExecuteJavaScript`. Round-trip a single service invoke across the render↔browser process boundary — prove the bridge *shape* maps onto CEF.
6. **Document-start injection.** Inject Zapp's bootstrap at context creation (render-process handler) — the WKWebView user-script analog.
7. **ZJS worker coexists.** Spawn one ZJS worker alongside; confirm it runs untouched.

## Go/no-go criteria (FINDINGS verdict)

| # | Criterion | Answers |
|---|---|---|
| 0 | CEF links into a Nim+ObjC build (arm64) & launches; `importc` handles `cef_*_t` + `ref_counted.h` | build/toolchain fit |
| 1 | Run-loop coexistence: CEF pump + `NSApplication` + ZJS/kqueue, neither starving (verdict: which mode) | **#1 risk** |
| 2 | CEF browser renders inside Zapp's existing `NSWindow` | hosting fit |
| 3 | One `zapp` bridge message round-trips JS→native→JS | bridge feasibility |
| 4 | Custom scheme serves an asset; brotli `br` decodes natively (measured) | perf-win #1 |
| 5 | A ZJS worker runs alongside untouched | edge survives |
| 6 | Cost data: `.app` size delta, cold-launch delta vs WKWebView, build-time delta, licensing (CEF BSD + Chromium) | is the size worth it |

**Verdict:** GO (design production cycle) / NO-GO (name the blocker) / GO-WITH-CAVEATS.

## Non-goals (YAGNI for the spike)

macOS arm64 only (no Windows/Linux/x86) · one window, CEF hardcoded (no end-to-end `webEngine` flag wiring) · one bridge message (no full host-object parity) · no packaging/signing/notarization polish (dev-run) · no inspector, navigation edge cases, multi-window, or per-window engine selection · not wired into `zapp build` · **WKWebView path 100% untouched — zero regression to `webEngine:"system"`.**

## Deliverable & gate

A running macOS window (**human visual gate**: renders a Zapp page + the bridge demo + a brotli-served asset + a running ZJS worker) and `spikes/cef-macos/FINDINGS.md` with the GO/NO-GO verdict + the measured cost/benefit table. Code lives in `spikes/cef-macos/` (throwaway-OK); being approach A, the scheme/bridge/hosting learnings seed the eventual production module. No unit tests (spike).

## Top risks (ordered)

1. **Message-loop coexistence** (gate 1) — CEF's multi-process pump vs `NSApplication` vs Zapp's ZJS/kqueue loop.
2. **Nim `importc` of the C-API refcount + callback-struct pattern** at scale.
3. **Framework/helper bundling** from a non-CMake (Nim) build.
4. **Bridge process-boundary semantics** (render vs browser process) differing from WKWebView's single-process model.

## Constraints

Branch `feat/cef-web-engine` off `feat/nim-native`, banked in place; pre-existing WIP stays unstaged; per-file commits; commit trailer exactly `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` + `Claude-Session: https://claude.ai/code/session_01DZ9M515fEUqt9EE2oFDyyv`; Bun not Node; NO iOS/Windows in this spike; WKWebView (`webEngine:"system"`) untouched.
