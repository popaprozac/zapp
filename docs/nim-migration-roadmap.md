# Nim Migration Roadmap — replacing Zen-C end-to-end

**Status:** living doc. Last assessed 2026-06-18 (branch `feat/nim-native`).

**Goal:** the Nim native layer (`native/nim/`) fully REPLACES the Zen-C (`.zc`)
native layer — not coexist. Today the Nim build is opt-in via
`ZAPP_NATIVE_LANG=nim`; the zc build is the default. (Decision background:
`docs/superpowers/specs/2026-06-15-nim-migration-design.md` and the
`2026-06-17-nim-app-*` specs.)

---

## Where Nim already stands (macOS)

**macOS module parity is essentially complete.** Every zc native responsibility
has a working Nim counterpart, proven end-to-end by the kitchen-sink running
entirely on the Nim build (smoke-verified 2026-06-18):

- app boot + run loop + message handler (`app.nim`), app events (`app_events.nim`)
- the JS↔native bridge wire protocol (verified wire-identical), router t:1/3/4/5/6
  (`router.nim`), dispatch/escape (`dispatch.nim`), protocol (folded into `bridge.nim`)
- service registry + invoke (`service.nim`), permissions (`permissions.nim`)
- full WindowManager — create / popover / `asSheetOf` / sidebar + inspector chrome
  (`window.nim`), window events + callbacks (`events.nim`, `callbacks.nim`)
- every leaf service: clipboard, dialog, dock, fs, menu, notification, panel,
  screen, shortcuts, sync, tray (matching `*.nim` each)
- zjs workers + worker registry/dispatcher (`registry.nim`, `worker.nim`), the
  worker→native service seam (`worker_service.nim`) — both the inline sync path
  (foreign-thread GC) and the async-to-main App-capable path
- all 18 `native/platform/darwin/*.m` files compile into the Nim build
- the app's own `zapp/app.nim` compiles as the build root (Shape-A managers)

Nim is actually **ahead** of zc on a few recent things (worker async invoke,
object-literal `WindowOptions`, unified `Inspectable` cascade, per-pane drag
regions) — these landed nim-first.

---

## The load-bearing catch: the "Nim" build still needs Zen-C

Even under `ZAPP_NATIVE_LANG=nim`, the build shells out to `zc transpile` twice:
1. the `JsonValue` C-ABI (`native/bridge/json_safe.zc` + `json_builder.zc`) is
   **reused, not ported** — transpiled + clang'd into `.zapp/zjson_provider.o`
   and linked (`cli/src/native.ts:~1193-1219`).
2. the zjs runtime is built from `vendor/zjs/src/lib.zc` via `zc transpile`
   (`cli/src/build-config.ts:~1253`, needs `ZC_ROOT`).

So "Nim replaces zc" cannot be literally true until these are de-zc'd. This is
the conceptual blocker, separate from any feature gap.

---

## Remaining gaps (suggested order)

| # | Gap | Size | Evidence / notes |
|---|---|---|---|
| 1 | ~~**Prod macOS build**~~ ✅ DONE 2026-06-18 | Medium | SHIPPED. `buildNativeNim` now threads `optimize` → prod build-config (`embedAssets`/`devTools`/`isDev`/`assetRoot`) + custom protocols; a new `renderAssetsNim`/`generateAssetManifestNim` emits a `staticRead` `{.exportc.}` brotli asset table (`.zapp/zapp_assets.nim`); `createProductionBundle` detects embedded assets via a language-agnostic `.zapp/assets-embedded` marker (also fixed a latent zc dev-stub bug). Nim build now produces a distributable, detached-capable binary + self-contained `.app`. **Assets are now zc-free** (down-payment on gap #2). Also fixed a pre-existing macOS bug the final review caught: `darwin/webview.m`'s embedded-asset serving was dead code (gated on a cross-TU `#ifdef` that never resolved) → swapped to the iOS-style runtime weak-symbol guard so embedded assets are actually served (fixes nim **and** zc distributable apps). Verified: nim+zc package both take the embedded branch; recompiled webview.o now imports the table + brotli decoder. Pending: human GUI smoke (detached launch). |
| 2 | **De-zc the build** | Medium | Port the `JsonValue` ABI to Nim (or emit it from Nim) + build zjs without `zc`. Removes the hidden Zen-C dependency — the gate for *deleting* zc. (Related: ticket #502 — drop the `{.emit.}` JsonValue mirror in `worker_service.nim` once a provider header / Nim ABI exists.) |
| 3 | **Deferred worker event fan-out** | Small–Medium | Layer-2/3 worker delivery is a documented no-op in the Nim build (`app_events.nim:9,77`; `callbacks.nim:10,87`). zc fans app/window events to workers; Nim drops them. |
| 4 | **bare-* engines** | Large | Nim build is **zjs-only** (`worker.nim:6-8,65-97`; `zapp.nim:204`). The whole bare-jsc/v8/quickjs/mqjs/hermes machinery — `ensureBareBuilt` (~450 lines, `native.ts:252-919`) incl. iOS/Windows engine cross-compiles — is never invoked from the Nim path. |
| 5 | **iOS** | Large | `buildNativeNim` is macOS-only: no `target` threading (hardcoded `platform:"macos"` at `native.ts:1126`, macOS clang/frameworks at `:1248`), the 18 `native/platform/ios/*.m` are unwired, no SDK/arch/bundle/plist/sign. A whole platform. zc reference: `native.ts:75-105,372-448`. |
| 6 | **Windows** | Large | No Windows in the Nim path at all (no MinGW/`cc` handling, no `windows/*.c` compile, no WebView2 link). zc reference: `native.ts:107-131,342-365`. |
| 7 | **Default-flip + zc removal** | Medium | Invert/delete the single env gate (`native.ts:1263`). hello-world has no `app.nim` so the **binary-size benchmark can't build under Nim** (`chooseNimRoot` throws, `native.ts:1062`) — add one. Rewrite zc-coupled tests: `ios-platform-parity.test.ts` + `windows-platform-parity.test.ts` (scan `.zc` for `darwin_*`/symbols), `test-native.ts` (runs `zc run`). Then delete `native/**/*.zc`. |

**Net shape:** macOS is ~there; the long pole is **iOS + Windows + bare engines**
(three Large items), gated behind **prod-build + de-zc-ing** (two Medium
prerequisites). #3 is behavioral parity polish.

---

## Open follow-up tickets that feed this
- #502 — `worker_service.nim` `{.emit.}` JsonValue mirror → `{.importc, header}` (subsumed by gap #2).
- #503 — Nim test hardcoded `$HOME`-absolute `zjson_provider.o` `passL` path (portability; matters once Nim tests run in CI).
- #495 — iOS native `setInspectable` ignores the inspectable cascade (`ios/window.m:341`) — folds into gap #5 (iOS).
- #504 (done as nim-only) — zc worker async-invoke parity is the inverse direction (zc catching up); not on the replacement path.

## Uncertainty flags (from the 2026-06-18 read-only assessment)
- Not every leaf-service `.nim` was diffed against its `.zc` for sub-feature
  parity beyond the self-documented deferrals — small per-service gaps may exist.
- Whether `createProductionBundle`/`createDevBundle` succeed end-to-end on a Nim
  binary is inferred from shared orchestration, not a packaging run.
