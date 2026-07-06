# CEF `webEngine:"chromium"` — first production slice (macOS) — design

**Date:** 2026-07-05
**Branch:** `feat/cef-webengine-prod` (off `feat/nim-native`; keeps `nim-native` stable for the Windows handoff)
**Type:** Production feature slice (opt-in), risk-gate-first. Builds on the de-risking spike (`spikes/cef-macos/`, VERDICT GO).
**Status:** design approved; pending spec review → writing-plans → SDD

## Goal

Turn the CEF spike's proven-in-isolation seams into a **real, usable opt-in path**: a fullbleed-web Zapp app that **renders on CEF and round-trips `Services.invoke`**, produced by the real `zapp build` when `webEngine:"chromium"` is set — on macOS, strictly opt-in, with `webEngine:"system"` (WKWebView) byte-identical to today.

**Bar = render + bridge.** Worker is deferred (the spike already showed ZJS coexists).

## Scope / constraints

- **macOS arm64 only.** No iOS/Windows/Linux this slice.
- **Strictly opt-in + gated.** `webEngine:"system"` builds do ZERO CEF work (no fetch, no compile, no bundle) and stay byte-identical. This is the load-bearing guarantee.
- Reuse the existing production seams verbatim: scheme `zapp://`; asset table `zapp_embedded_assets[]` (fields `is_brotli` / `uncompressed_len`, decode when `is_brotli && uncompressed_len>0`); the `"zapp"` script-message bridge → Nim router (`didReceiveScriptMessage`'s target).
- Promote + adapt the spike's CEF host (don't rewrite); apply the FINDINGS production seeds where this slice touches them.
- Branch banked in place; NO merge to `feat/nim-native` without explicit ask (that branch is the Windows handoff). Per-file `git add`; pre-existing WIP stays unstaged. Commit trailer exactly `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` + `Claude-Session: https://claude.ai/code/session_01DZ9M515fEUqt9EE2oFDyyv`. Bun not Node.

## Reference

The spike: `spikes/cef-macos/` + `spikes/cef-macos/FINDINGS.md` (GO verdict + production seeds). CEF 144, raw C API, external message pump, the ref-ownership rule, the brotli-in-handler (`78fb514`) path. This slice **promotes + rewires** that code; it does not start from scratch.

## Architecture — a gated parallel CEF webview host

macOS window creation branches `WKWebView` (default) ↔ `CEF` (when resolved `webEngine=="chromium"`). The CEF host lives in `native/platform/darwin/cef/`, promoted from the spike (`zapp_cef_*` naming), rewired to the real asset table + real router. The CEF fetch/compile/bundle lives inside `generatePlatformConfig`/`buildNativeNim`, entirely gated on `chromium`.

### §1 — Config / opt-in switch
- `cli/src/config.ts`: relax `validateWebEngine` to accept `"chromium"` (drop the throw; keep a "macOS-only, early-access" warning; still reject other values). Default `"system"` unchanged.
- Thread the resolved `webEngine` to two consumers: (a) `buildNativeNim`/`generatePlatformConfig` (gate the CEF build), (b) window creation (branch the host). Prefer a single resolver so both read the same value.

### §2 — CEF host module (`native/platform/darwin/cef/`)
Promote the spike sources (`cef_app.c`, `cef_client.c`, `mac_entry.m` init/pump, `mac_helper.c`, `host.m`, `bridge.c`, `scheme_handler.c`, `cef_refcount.h`, the glue header) renamed `zapp_cef_*`, drop "spike". Three adaptations:
- **Scheme handler** → serves the real `zapp_embedded_assets[]` weak table on `zapp://`, decoding brotli in-handler exactly as `ZappAssetSchemeHandler` does (`is_brotli && uncompressed_len>0`), reusing the same brotli decoder the WKWebView path uses (static-linked). Honors `zapp_build_use_embedded_assets()` — dev mode → point CEF at the Vite `devUrl` instead of embedded assets.
- **Bridge** → the browser-process message handler routes to the **same Nim router entry** `didReceiveScriptMessage` calls (replace the `greet` stub). Native→JS via `execute_java_script` for events / `postToWebview`. The render↔browser process protocol + the ref-ownership rule (Wrap=release / Unwrap-consumed=don't) carry over from the spike; fix the scheme-handler `refptr_diff` leak the spike final-review flagged.
- **Message loop** → CEF's external pump integrates with **Zapp's existing `NSApplication` run loop** (production already owns it; the spike owned its own). **THE #1 INTEGRATION RISK** — same shape as the spike's T1 but against the real loop. Proven at R0.

### §3 — Window-creation branch (`window.nim` / `window.m`)
At webview creation, when resolved `webEngine==chromium`, create the CEF browser into the window's content view instead of WKWebView. CEF windows are **fullbleed-web only** — the branch skips the sidebar/inspector/toolbar/pane machinery (WKWebView-only this slice; a `chromium`+native-chrome app is out of scope / a future cycle). Dev → `devUrl`; prod → `zapp://` embedded. Keep the WKWebView path untouched on the `system` branch.

### §4 — Build integration (`generatePlatformConfig` / `buildNativeNim`), gated on `chromium`
1. **Fetch CEF** (cached under a build-cache dir; reuse `fetch-cef.sh` resolve+sha1 logic; the ~110 MB minimal dist).
2. **Compile** the CEF `.c/.m` into the Nim build (add to the `.m`/`.c` list `renderPlatformNim` emits, gated).
3. **Bundle** the `Chromium Embedded Framework.framework` + the Helper `.app`s into the output `.app`'s `Contents/Frameworks` (+ `@rpath`/install-name handling from the spike's `build.sh`).
4. **Link** `libcef` + the framework + a **static** brotli decoder.
`system` builds run NONE of this — verified byte-identical.

### §5 — Test app + smoke gate
A minimal **fullbleed-web** fixture (NOT kitchen-sink — that's native-chrome-heavy): `webEngine:"chromium"`, one `greet` service, a button that `Services.invoke("greet")` and renders the result. Smoke:
- `zapp build` (chromium) → `.app` **renders** on CEF **and** the button **round-trips** the service.
- A `webEngine:"system"` build of the same app is **byte-identical to pre-change** (zero CEF), proving the gate.

### §6 — Risk order + non-goals
- **R0 (RISK GATE):** `buildNativeNim` gated-fetch+compile+bundle CEF, and a real fullbleed-web app **renders** through `zapp build` — loop integration into Zapp's NSApplication loop proven, NO bridge yet.
- **R1:** the `zapp` bridge round-trip (`Services.invoke` → router → result to JS).
- **Non-goals:** worker on CEF, DevTools, multi-window, native chrome (sidebar/inspector/toolbar) on CEF, Helper signing/notarization, iOS/Windows/Linux, per-window engine selection (app-wide `webEngine` only), navigation/back-forward.

## Top risks (ordered)
1. **CEF external pump ↔ Zapp's existing NSApplication run loop** (§2, R0) — the spike owned its loop; here CEF must slot into Zapp's.
2. **Gated build integration** (§4) — fetch/compile/bundle inside `buildNativeNim` without perturbing `system` builds.
3. **Bridge → real router** (§2, R1) — routing to the real router entry (not the stub) with correct arg/result marshalling + ref ownership.
4. **Brotli decoder** — static-linking the same decoder the WKWebView asset path uses (no Homebrew).
