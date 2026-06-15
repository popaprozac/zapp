# Nim Migration — Design

**Status:** Design (approved 2026-06-15). Implementation plan to follow.
**Branch:** `feat/nim-native` (off `main`).
**Decision provenance:** the native-language-eval spike (`spike/native-language-eval`,
`spikes/lang-eval/SCORECARD.md`) evaluated Zig / Nim / C3 / Odin / plain-C / Swift
against Zen-C. On the **maturity + adoption** lens the user elected **Nim**:
cleanest migration (compiles to C exactly like Zen-C, `{.emit.}` ≈ `raw` blocks),
stable, approachable, small binaries (102 KB probe floor, *under* the 112 KB Zen-C
baseline), zero API drift across probe + slice.

---

## Goal

Replace Zapp's ~7,500-line **Zen-C** (`.zc`) native orchestration layer with
**Nim**, validated by a **skeleton-first greenfield rebuild** on an isolated
branch — proving the real Nim-driven build + orchestration ergonomics on the
actual codebase before committing to the full breadth port.

## Non-goals (this spec)

- **Not** a coexistence pilot (Nim modules linked into the `zc` binary). We
  evaluated that and rejected it: the coexistence scaffolding is throwaway work
  that does not transfer to the end state, and it keeps `zc` as the build driver —
  hiding the exact Nim-driven-build ergonomics we want to learn.
- **Not** the platform layer. The 18 darwin `.m`, 18 iOS `.m`, and 19 Windows
  `.c` files (~20k lines) are **reused untouched**, called via Nim `importc`.
- **Not** iOS or Windows for the skeleton — macOS only. iOS + Windows are Phase 2
  parity work.
- **Not** a `main` merge until full parity is reached. `main` keeps shipping on
  `zc` the entire time.

## Guiding principle — write idiomatic Nim

The migration is a **re-expression in idiomatic Nim, not a mechanical
transliteration of Zen-C**. Just as the Zen-C layer made it an explicit goal to
lean into native Zen-C features and drop to `raw {}` only when necessary, the Nim
port leans into Nim's features and reaches for inline C (`{.emit.}`) only when
genuinely unavoidable. **Where Zen-C used a pattern but Nim has a better
mechanism, use Nim's.** Illustrative (not exhaustive — the real list is
discovered per module and recorded in the assessment):

- Manual `char*` + `malloc`/`free` + static-slot lifetime hacks → native `string`
  / `seq[byte]` with ORC-managed memory (the clipboard static-slot idiom simply
  disappears).
- `if str::strncmp(method, …)` dispatch chains → a native string `case … of`.
- Sentinel / empty-string error returns → `Option[T]` (std/options) or
  exceptions, whichever reads cleaner per call site.
- Magic int event / message codes → an `enum`.
- Opaque `void*` handles → `distinct` types for compile-time safety.
- Repetitive registration / dispatch boilerplate → a `template`/`macro` **only
  where it genuinely removes noise** (no macro-for-its-own-sake).
- `raw { … }` ObjC/C blocks → a clean `{.importc.}` of the existing `.m` C-ABI;
  `{.emit.}` is reserved for the rare unavoidable case (the analogue of "`raw`
  only when necessary").

This is not gold-plating — it **is the evaluation**. The point of a greenfield is
to learn Nim's ergonomics on real code, and writing idiomatic Nim (not
transliterated Zen-C) is the only way to find out whether Nim is meaningfully
nicer. The ergonomics assessment (the deliverable) records, per module, **where
idiomatic Nim improved on the Zen-C pattern** — and where it didn't.

## Success criteria (the go/no-go gate)

The skeleton passes when, on macOS:

1. **Sub-gate A — build ergonomics:** the Nim-driven build (`nim c`, not
   `zc build`) produces a `.app` that shows a window whose `WKWebView` loads the
   bundled assets. Proves Nim drives the build, `.m` files compile via
   `{.compile.}`, frameworks link, and assets embed.
2. **Gate B — language ergonomics on the hard path:** hello-world round-trips one
   bridge call (a button invokes the `greet` service and renders the response)
   **and** clipboard read/write works (text + html + files). The build's final
   line is `[zapp] build complete: <path>` with a fresh binary mtime; verified by
   manual smoke.

The **deliverable** is not just a passing gate — it is a written **ergonomics
assessment**: the Nim-driven build + the orchestration port graded against the
Zen-C friction inventory, so we can decide "continue to full migration" vs "stop"
with evidence. `main` is unaffected throughout.

---

## Architecture

### Build model — Nim is the driver

Today: `cli/src/native.ts` assembles a `zc build <build.zc> <generated .zc> -I … -o …`
invocation; `zc` walks `import` statements from `native/build.zc` → `app/app.zc` →
~15 module imports, emits one C file, and invokes clang once (compiling the `.m`
platform sources passed via `//> cflags:` directives and linking frameworks via
`//> link:`).

After: the native-build step calls **`nim c`**. A Nim root module
(`native/zapp.nim`) imports the orchestration modules. The platform layer and
build flags come in through Nim pragmas:

- **`{.compile: "platform/darwin/window.m".}`** — one per platform `.m`/`.c`
  source; Nim compiles and links it. (Replaces the `//> cflags: <.m list>`.)
- **`{.passC: "-fobjc-arc -x objective-c -I native".}`** — ObjC ARC + the include
  path for the platform `.h` files.
- **`{.passL: "-framework Cocoa -framework WebKit …".}`** — frameworks + link
  libraries. (Replaces `//> link:`.)
- **`--mm:orc -d:release --opt:size`** — the ORC GC (kept, ~free in size per the
  spike) and size-optimized release.

### The interop boundary — bidirectional, good patterns (not debt)

The `.m` files are reused untouched, so the boundary is **bidirectional C-ABI** —
and a deliberate review (2026-06-15) confirmed each interaction is a standard,
functionally-correct pattern, *not* carried-over Zen-C debt. The debt risk in
this migration is transliterating Zen-C's compiler-fighting idioms (raw blocks,
manual memory, sentinel returns) into Nim — which the *Guiding principle* already
forbids; that cruft lives in the `.zc` and evaporates in Nim regardless of the
boundary.

- **Nim → `.m` (`importc`):** bind the existing `darwin_*` / `windows_*` C symbols
  (`proc darwin_window_create(opts: pointer): pointer {.importc, cdecl.}`). Plain
  FFI — the analogue of today's `import "…/window.h"`. A `raw { darwin_… }` block
  becomes a direct `importc` call — **no inline ObjC**. *Fundamental, good.*
- **`.m` → Nim (`exportc`):** the untouched `.m` files call *back* into the
  orchestration layer via C symbols Nim must `{.exportc, cdecl.}`:
  - `zapp_handle_message_from_window(app, msg, window_id)` — WKWebView delivers JS
    messages here. *Fundamental* (something must bridge the Cocoa callback to the
    router).
  - `zapp_build_*()` config getters (~12) + `zapp_webview_bootstrap_script()` —
    config "pull" for cheap build-time constants. *Standard pattern* (push-a-struct
    would only add coupling). These are GENERATED as Nim.
  - `wopts_*(opts)` accessors (~40) — `window.m` reads `WindowOptions` through an
    **opaque handle + accessors**. This is textbook C encapsulation (decouples the
    `.m` from the struct layout; the shared-struct alternative is terser but
    couples `.m` to exact field layout → silent ABI mismatch on change). *Kept as a
    deliberate decoupling choice, not a Zen-C artifact.* Verbosity is the only cost
    and it is mechanical.
- **Nim ↔ Nim (orchestration):** normal Nim `import` between modules — **no
  `exportc` between orchestration modules** (only at the Nim↔`.m` edge). A key
  simplification over the rejected coexistence approach.

**Three boundary rules (to design out latent footguns — the only real debt
risks):**
1. **cstring lifetime:** every `exportc` getter returns a `cstring` backed by a
   module-level `let`, never a temporary string literal (the `.m` may read it past
   the call). Use-after-free otherwise.
2. **No `{.emit.}`:** any C-struct ABI the `.m` reads directly (e.g. the
   `ZappEmbeddedAsset` asset array) is a layout-matched `{.exportc.}` Nim object,
   not an inline `{.emit.}` block. `{.emit.}` is the Nim analogue of a `raw` block —
   reserved for the genuinely unavoidable, and flagged when used.
3. **Build-path fork is time-boxed:** the `ZAPP_NATIVE_LANG=nim` switch that
   selects `nim c` vs `zc build` is explicit temporary scaffolding, **deleted at
   cutover** when Nim becomes the only native build. Documented as temporary, not
   silently permanent.

(A single "host vtable" struct the `.m` calls through instead of loose C symbols
was considered and rejected: cleaner in the abstract but requires editing every
`.m` for no functional gain — churn/gold-plating we don't need. Noted as a
far-future option only.)

### Performance parity (non-negotiable)

Least-overhead webview↔native and **zero-overhead worker↔native** are top-tier
priorities; the migration must preserve them, not just functionally work.

- **Webview bridge:** inherently async (WKWebView has no sync JS→native). The Nim
  layer reproduces the existing `zc` wire protocol exactly (`postMessage` →
  `zapp_handle_message_from_window` → `darwin_window_eval_js` →
  `_onInvokeResult`). Verified wire-identical in the skeleton. No new concession
  permitted here — same single JSON parse + eval-back.
- **Worker host objects (Phase 2, the differentiator):** `Services.invokeSync`
  and the zero-JSON `service_invoke_native` direct path must stay
  **synchronous, in-process, and allocation-free**. A Nim `{.exportc, cdecl.}`
  proc is a plain C symbol — calling it from a JS engine host object is identical
  overhead to a `zc`-emitted C function — BUT the hot path must NOT convert
  `cstring`→Nim `string` or marshal JSON (those allocate via ORC). Keep
  pointer/scalar-based; ORC must never touch the zero-JSON call path.
- **Gate:** the worker-engine migration is not accepted until a **micro-benchmark
  proves host-object round-trip parity with the `zc` baseline** (~2.1 µs JSC /
  0.3 µs txiki today). The ergonomics assessment records the numbers.

### Repo layout

- Work **in place in `native/`** on `feat/nim-native`. Keep the `.zc` files as
  living reference; add `.nim` files beside them; **delete each `.zc` as its
  `.nim` replacement lands**. The Nim build compiles only `.nim` + the `.m`/`.c`
  it `{.compile.}`s, so leftover `.zc` is inert until removed.
- The platform layer (`native/platform/{darwin,ios,windows}/`) is untouched.

### Codegen (CLI, Bun/TS)

- `cli/src/generate.ts` (TS service wrappers in `src/zapp/`) — **unchanged**
  (runtime-side, language-agnostic).
- `cli/src/build-config.ts` — **changed**: the generated build-config / platform /
  headless / bootstrap / assets files become generated **`.nim`** (emitting
  `{.compile.}` / `{.passL.}` directives + embedded asset/bootstrap data) instead
  of `.zc`. This is the bulk of the CLI change.
- `cli/src/native.ts` — swap the `zc build …` argv assembly for `nim c …`.

---

## Phase 1 — the walking skeleton

Port only the load-bearing spine, in dependency order:

| Order | Module(s) | Proves |
| --- | --- | --- |
| 1 | build entry (`native/zapp.nim` root) + generated Nim build config | Nim drives the build; `.m` compiles; frameworks link |
| 2 | `platform/platform.zc` → `platform.nim` (`platform_init`) | `importc` of `darwin_platform_init`; `when defined(macosx)` |
| 3 | `app/app.zc` → `app.nim` (lifecycle, `App.run` → platform run loop) | app object + run loop via `importc` |
| 4 | `window/window.zc` (+ events/callbacks) → `window.nim` (one window + webview) | window create + `WKWebView` + asset load (→ **sub-gate A**) |
| 5 | `bridge/protocol.zc` + `bridge/dispatch.zc` + `app/router.zc` → `.nim` (one round-trip) | JSON parse + dispatch + the host-bridge round-trip (the crux) |
| 6 | `service/service.zc` → `service.nim` (register + invoke one service) | `greet` service invoked from JS |
| 7 | `clipboard/clipboard.zc` → `clipboard.nim` (first leaf feature) | the full module-port recipe end-to-end (→ **gate B**) |

**Sub-gate A** falls out of step 4; **gate B** falls out of steps 5–7. If a
Zen-C feature with no clean Nim equivalent exists, it surfaces *here* — days in,
not weeks — which is the entire point of skeleton-first.

### Clipboard as the recipe exemplar

`clipboard.zc` (197 lines) is the template every later module follows:

- Current shape: `struct Clipboard {}` + `impl Clipboard` with `@cfg`-gated
  methods, each a `raw { … }` block calling `darwin_clipboard_*` /
  `windows_clipboard_*`, plus a manual static-buffer ownership idiom (keep the
  malloc'd C buffer alive in a `static char*` slot until the next call).
- Nim shape: a module that `importc`s the `darwin_clipboard_*` C-ABI, exposes
  `proc readText(): string` etc. The static-slot memory hack collapses — Nim
  converts the returned `cstring` to a `string` (copying) and the C buffer is
  freed immediately; no slot needed. `@cfg(apple)`/`@cfg(windows)` →
  `when defined(macosx)` / `when defined(windows)`. JSON for `read_files` is just
  the returned string (services parse it; clipboard does not).
- Caller change: `router.zc:1774-1815` calls `Clipboard::read_text()`,
  `write_text`, `read_html`, `write_html`, `read_files`, `has`, `clear`. In the
  Nim router these become normal Nim calls into `clipboard.nim`
  (`clipboard.readText()`), because the router is *also* Nim by the time clipboard
  lands (step 5 precedes step 7). The image path
  (`darwin_clipboard_read_image_png_b64`, router:1825/1848) stays a direct
  `importc` call — image bytes are intentionally absent from the high-level
  surface — so that boundary is unchanged.
- Windows branch: ported as a `when defined(windows)` block calling
  `windows_clipboard_*`; **compile-checked only on macOS** (the dead branch isn't
  compiled), verified for real later on the Windows machine.

---

## The reusable module-port recipe

The recipe is **re-express idiomatically** (see *Guiding principle*), not
transliterate. The mappings below are sensible defaults, not a ceiling — if Nim
offers a cleaner mechanism than the Zen-C pattern, take it.

For each remaining `.zc` module:

1. Create `<module>.nim`.
2. `importc` the platform C-ABI it calls (from the existing `.h` signatures).
3. Rewrite each `raw { … }` block as a direct `importc` call — **no inline ObjC**
   (`{.emit.}` only if genuinely unavoidable).
4. Re-express the orchestration in idiomatic Nim — default mappings: `struct` +
   `impl` → `object` + `proc` (UFCS); `@cfg(apple/windows)` →
   `when defined(macosx/windows)`; `std/json` (`JsonValue::parse`, `get_int`,
   `get_string`) → Nim `std/json` (`parseJson` + typed getters, or `to(T)` object
   mapping where it reads better), with `hasKey`/`getOrDefault` guards on
   untrusted bridge frames (Nim's `[]` raises on a missing key); manual memory →
   native `string`/`seq`; magic codes → `enum`; opaque handles → `distinct` — and
   reach further into Nim (variants, templates) where it genuinely simplifies.
5. Expose the module's API as a normal Nim module (no `exportc`).
6. Delete the `.zc`; add the module to the Nim root import.
7. Note in the ergonomics assessment where idiomatic Nim beat (or didn't beat) the
   Zen-C original.

---

## Phase 2 — breadth + parity (post-gate, separate plans)

After the gate passes, the remaining ~35 modules are mechanical ports of the
recipe: `menu`, `tray`, `dock`, `dialog`, `notification`, `screen`, `sidebar`,
`inspector`, `toolbar`, `popover`, `panel`, `fs`, `permissions`, `shortcuts`,
`sync`, `log`, `app_events`, plus worker-engine wiring. Then **iOS** and
**Windows** parity. **Merge to `main` once, at full parity.** Each module (and
each platform parity pass) is its own task in a later plan — this spec covers
through the gate.

---

## Risks & mitigations

- **ObjC-via-Nim build (highest-priority unknown):** does `-x objective-c
  -fobjc-arc` thread cleanly through Nim's `{.compile.}` of the `.m` files, and
  do the frameworks link? This is the *first* thing the skeleton proves
  (sub-gate A). If it doesn't work out of the box, the fallback is precompiling
  the `.m` files to a `.a` (as the Bare runtime already does) and `{.passL.}`-ing
  that archive — a known-good pattern in the repo.
- **GC init:** Nim-as-driver owns `main`, so the ORC GC initializes normally (no
  manual `NimMain()` — that was only needed for the rejected staticlib/coexistence
  path).
- **Showstopper feature:** any `.zc` construct with no clean Nim equivalent
  surfaces during the spine port (skeleton-first guarantees early discovery).
- **Asset/bootstrap embedding:** the generated `.zc` that embeds brotli assets +
  the JS bootstrap must be reproduced as generated `.nim` (embedded `const`
  byte arrays / `staticRead`); validated at sub-gate A.

## Future (out of scope, recorded)

- **`zig cc` as Nim's C backend compiler** for self-contained
  **Windows-from-Mac** cross-compilation — Nim lets you pick the backend C
  compiler, and `zig cc` bundles Zig's cross-compile. Closes the one axis Nim
  lost to Zig in the spike. Applies to the Phase 2 Windows parity work (the
  Windows platform layer is plain C; Cocoa/`.m` is Apple-only regardless of
  compiler).
- **iOS toolchain gating** reuses the lessons from the bare-hermes iOS build
  (cross-compile tool gating, SDK selection).

## References

- `spikes/lang-eval/SCORECARD.md` — the evaluation + recommendation.
- The Zen-C friction inventory (in the scorecard + project memory) — the baseline
  the ergonomics assessment grades against.
- `cli/src/native.ts:1073-1101` — current `zc build` invocation (becomes `nim c`).
- `cli/src/build-config.ts` — current `.zc` codegen (becomes `.nim` codegen).
- `native/clipboard/clipboard.zc` + `native/app/router.zc:1774-1848` — the pilot
  module + its callers.
