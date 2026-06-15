# Nim Migration — Phase 1 Skeleton Ergonomics Assessment

**Date:** 2026-06-15 · **Branch:** `feat/nim-native` · **Scope:** the walking
skeleton (Tasks 0–6), macOS only.

**What was built:** a fully **Nim-driven** Zapp build (`nim c`, not `zc build`)
that renders the real hello-world UI, round-trips a `greet` service call, and
does full clipboard (text / html / files / image) — with the entire 18-file
ObjC `.m` platform layer **reused untouched**. 8 Nim modules
(`platform/app/window/bridge/service/router/clipboard/zapp`), ~600 lines.

**This is the deliverable:** evidence to decide *continue the full migration* vs
*stop*, graded against the Zen-C friction inventory. **Verdict up front:
CONTINUE** (see §5), with the worker host-object micro-benchmark as the next hard
gate.

---

## 1. Build ergonomics (Nim as the driver)

**Result: clean, and the riskiest unknown cleared first.**

- **ObjC compiles through Nim directly.** `{.compile("…/window.m",
  "-fobjc-arc").}` compiles the untouched `.m` files and links Cocoa/WebKit —
  no precompiled-`.a` fallback needed (Task 1 was deliberately the #1-risk
  de-risk; it passed). The `.m` layer is genuinely reusable as-is.
- **The CLI swap was small.** `zc build … ` → `nim c …` is one `buildNativeNim`
  function (`cli/src/native.ts`), env-gated by `ZAPP_NATIVE_LANG=nim`; the `zc`
  path stays the untouched default. Generated build-config + bootstrap are
  re-emitted as Nim (`renderBuildConfigNim`/`renderBootstrapNim`, bun-tested) and
  pulled in via `--path`. Nim owns `main`, so ORC initializes itself (no manual
  `NimMain`).
- **Build is fast** and the toolchain "just works" (zero API drift across the
  whole skeleton — the maturity signal the spike predicted).

**The one sharp footgun:** `{.compile.}` has a **tuple form** `{.compile: (file,
x).}` where `x` is the *output object name*, not flags — silently dropping
`-fobjc-arc` and clobbering every `.m` into one object. The **call form**
`{.compile("file", "-fobjc-arc").}` is correct (3rd arg = per-file flags). It
only surfaced once *multiple* `.m` compiled (Task 4a); a single-`.m` proof masked
it. Now documented in the plan + every module. One-time lesson, but a real one.

## 2. Bidirectional ABI (the `.m` ↔ Nim contract)

**Result: works cleanly, larger surface than first sketched, no `{.emit.}`
anywhere.**

- **Nim → `.m`:** plain `importc, cdecl` FFI. Trivial.
- **`.m` → Nim:** the untouched `.m` files call back into ~60 C symbols Nim must
  `{.exportc, cdecl.}` — **44 `wopts_*` accessors** + ~15 callbacks
  (`zapp_handle_message_from_window`, the `zapp_build_*` getters,
  `zapp_dispatch_event`, `service_get_manifest_json`, accessory `*_unregister`,
  `app_get_*`). All plain Nim exportc — **zero `{.emit.}`** in the whole skeleton.
  The count is dictated by how much `window.m`/`webview.m` do (sidebar / inspector
  / toolbar / popover), not by Nim. Per the boundary review, this opaque-handle +
  accessor shape is a deliberate decoupling pattern (kept), not Zen-C debt;
  verbose but mechanical (many `wopts_*` are one-line default returns the skeleton
  never exercises).
- **Two ABI disciplines that must be remembered** (both now codified as rules):
  1. **`GC_ref` pinning** — a Nim `ref` handed to C (e.g. `WindowOptions`) must be
     `GC_ref`'d so ORC doesn't collect it while `window.m` holds the pointer past
     the call. The one non-obvious ORC↔C ownership rule.
  2. **cstring lifetime** — `exportc` getters returning a non-empty `cstring` are
     backed by module-level `let`s (a returned temporary would dangle).
- **Reconciliation discipline:** when an `.m` provides a real symbol, the Nim
  stub for it must be removed (a `darwin_webview_eval_all` duplicate-symbol
  collision caught this). The recipe: grep each newly-compiled `.m`'s `extern`
  surface, dedup.

## 3. Idiomatic wins — per module (the point of writing idiomatic Nim)

These are concrete, measured against the actual `.zc` they replace:

- **clipboard** — the headline. The `.zc` used **7 `raw{}` blocks**, each with a
  function-`static char*` slot kept alive across calls (leak-by-design) to keep a
  borrowed pointer valid. In Nim that entire idiom **collapses to one 6-line
  `takeCString`** (`$p` copies, then `c_free`). No `raw`, no static slot, no
  Foundation.
- **router** — the `.zc` hand-rolled a ~20-line **stack-buffer JSON-string
  escaper** (`cb_str_envelope[8192]` — the same buffer-truncation-bug family that
  bit `json_safe`/`dispatch` historically). In Nim it's `$(%str)` from
  `std/json`. Method dispatch went from an `if/else-if` ladder with
  `did_handle`/`is_string_result` bookkeeping flags to a single native string
  `case`.
- **service** — linear `g_services[]` C array + `raw` `for`/`strcmp` →
  `Table[string, ServiceHandler]` + `Option` return.
- **bridge** — `JsonValue::parse` + `get_*` → `std/json` with guarded `{}` access
  (returns nil/default on a missing key instead of raising — the defensive-JSON
  the design called for, for free).
- **build-config codegen** — Nim string emission with `let`-backed cstrings;
  comparable to the `.zc` emitter, slightly cleaner.

The recurring theme: **the patterns Zen-C had to hand-roll (manual buffer
lifetimes, stack-buffer escapers, linear registries, raw blocks) are stdlib
one-liners in Nim.** This is the genuine ergonomic improvement the greenfield set
out to measure — and it held on real code, not a toy.

## 4. Idiomatic costs / surprises (honest column)

- **The `{.compile.}` tuple/call footgun** (§1) — sharp, build-time, now known.
- **Bidirectional `exportc` surface is large** (~60 symbols) — mechanical, but
  real typing; mostly default-returning `wopts_*` stubs.
- **ORC↔C ownership** needs the `GC_ref` discipline for C-held refs — easy to
  forget, garbage/UAF if you do.
- **Contract-matching needs source-of-truth reads, not guesses** — exact arg keys
  (`"format"` not `"fmt"`, `"data"` not `"b64"`) and the bare-token error
  convention (`NOT_FOUND`, not JSON-quoted, because `webview.ts` does
  `new Error(payload)`) had to be read from the runtime/zc. Same as any port, but
  the skeleton confirms you must read, not assume.
- **A blank-webview debugging detour** — *not* a Nim issue: hello-world's entry
  module top-level-`await`s `greet()` before mounting `#app`, so a dead bridge
  (two not-yet-wired stubs) hung the await → blank page. Worth recording because
  it shows the webview render and the bridge are entangled for this demo (and the
  lldb "index.html was served" check was insufficient — render needs the bridge).

## 5. Performance

- **Webview bridge: wire-identical to `zc`.** lldb confirmed byte-for-byte the
  same `_onInvokeResult` IIFE + `darwin_window_eval_js` path as
  `dispatch.zc:dispatch_invoke_response`. No regression. (Inherently async —
  WKWebView has no sync JS→native; that's a WebKit trait, unchanged.)
- **Worker host-object zero-overhead path: NOT in the skeleton** (Phase 2). The
  spec marks it a non-negotiable success criterion: `Services.invokeSync` /
  `service_invoke_native` must stay synchronous + **allocation-free** (a Nim
  `exportc` proc is a plain C symbol = identical overhead to `zc`-emitted C, *as
  long as* the hot path never `cstring`→`string`s or marshals JSON → ORC must
  never run there). **This is the single most important thing still to prove** —
  gated by a micro-benchmark vs the `zc` baseline (~2.1 µs JSC / 0.3 µs txiki).
- **Size:** the skeleton binary is ~296 KB *with* all platform `.m` + WebKit +
  filesystem-served assets — that's the app, not Nim overhead (the Nim runtime
  floor measured 102 KB in the spike, *under* Zen-C's 112 KB). ORC adds ~0.1%
  (it's deterministic ARC + cycle collector, not a stop-the-world GC) — kept
  deliberately; `--mm:none` was rejected (negligible size win, unsafe leak).

## 6. Verdict — CONTINUE to Phase 2

The skeleton proves three things the migration bet depended on:

1. **Mechanically viable** — Nim drives the build, reuses the `.m` layer
   untouched, and the bidirectional ABI is clean (no `{.emit.}`). The risky
   unknowns (ObjC-via-Nim, asset/bootstrap wiring, the bridge) all cleared.
2. **Ergonomically better** — idiomatic Nim collapsed the exact Zen-C pain points
   (manual buffer lifetimes, stack-buffer escapers, raw blocks, linear
   registries) into stdlib one-liners, on real code. The idiomatic-Nim principle
   paid off; it wasn't transliteration.
3. **Performance-neutral where measured** — the webview bridge is wire-identical
   to `zc`; no regression on the path the skeleton exercises.

The costs (the `{.compile.}` footgun, the `exportc`/`GC_ref` disciplines, the
large-but-mechanical accessor surface) are one-time and now codified. None is a
blocker.

**Recommended next steps (Phase 2, separate plans):**
- **First, the perf gate:** stand up one worker engine (zjs or a bare engine) host
  object in Nim and **micro-benchmark `Services.invokeSync` round-trip vs the `zc`
  baseline.** This is the one unproven perf-critical piece and the differentiator;
  do it before broad breadth so a surprise surfaces early (skeleton-first logic,
  again).
- **Then breadth-port** the remaining ~35 orchestration modules via the proven
  recipe (menu/tray/dialog/notification/dock/screen/sidebar/inspector/toolbar/
  popover/panel/fs/permissions/shortcuts/sync/log + worker wiring), each replacing
  its `.m` callback stubs as it lands.
- **Then** iOS + Windows parity (the `zig cc`-as-Nim-backend lever for
  Windows-from-Mac cross-compile is the recorded option), and finally the single
  `main` merge at parity.

**Deferred from the skeleton** (tracked, not blocking): the brotli-**embedded**
asset Nim emitter (skeleton uses the filesystem asset path; embedded is the
production-packaging path, the counterpart to `cli/src/assets.ts`); the worker
engines; everything in breadth above.
