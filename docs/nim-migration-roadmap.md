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

## The load-bearing catch: the "Nim" build and Zen-C

Historically, even under `ZAPP_NATIVE_LANG=nim` the build shelled out to
`zc transpile` per build. **Piece A removed that** (2026-06-18): the `JsonValue`
C-ABI is now `native/nim/jsonvalue.nim` (JsonNode-backed; in the module graph
via `worker_service.nim`), so there is no per-build `zc transpile`, no
`.zapp/zjson_provider.o`, and no `--passL`. The remaining zc touchpoint is **not
a per-build dependency**: the zjs runtime is vendored as a prebuilt
`libzjs.dylib` the Nim build links directly (no `zc` per build). Committing a
vendored zjs artifact — so a zc-less machine (a second dev/CI host, prod
packaging) can build from a clean clone — is **deferred** (gap #2, Piece B).

So a day-to-day Nim build on a machine that already has the vendored
`libzjs.dylib` no longer invokes `zc` at all.

---

## Remaining gaps (suggested order)

| # | Gap | Size | Evidence / notes |
|---|---|---|---|
| 1 | ~~**Prod macOS build**~~ ✅ DONE 2026-06-18 | Medium | SHIPPED. `buildNativeNim` now threads `optimize` → prod build-config (`embedAssets`/`devTools`/`isDev`/`assetRoot`) + custom protocols; a new `renderAssetsNim`/`generateAssetManifestNim` emits a `staticRead` `{.exportc.}` brotli asset table (`.zapp/zapp_assets.nim`); `createProductionBundle` detects embedded assets via a language-agnostic `.zapp/assets-embedded` marker (also fixed a latent zc dev-stub bug). Nim build now produces a distributable, detached-capable binary + self-contained `.app`. **Assets are now zc-free** (down-payment on gap #2). Also fixed a pre-existing macOS bug the final review caught: `darwin/webview.m`'s embedded-asset serving was dead code (gated on a cross-TU `#ifdef` that never resolved) → swapped to the iOS-style runtime weak-symbol guard so embedded assets are actually served (fixes nim **and** zc distributable apps). Verified: nim+zc package both take the embedded branch; recompiled webview.o now imports the table + brotli decoder. Pending: human GUI smoke (detached launch). |
| 2 | **De-zc the build** | Medium | **Piece A: ✅ DONE 2026-06-18.** The per-build `zc transpile` of the `JsonValue` provider is removed; the `JsonValue` C-ABI is now `native/nim/jsonvalue.nim` (JsonNode-backed) — unifying the worker arg type on `std/json`'s `JsonNode`, which eliminates the old `JsonValue`→`JsonNode` walk. `worker_service.nim` imports it via the module graph; no `.zapp/zjson_provider.o`, no `--passL`. Closes #502 (`{.emit.}` JsonValue struct mirror) and #503 (hardcoded `$HOME` provider `.o` `passL`, in two test files). **Piece B: DEFERRED.** zjs is already vendored as a prebuilt `libzjs.dylib` the Nim build links WITHOUT `zc` per build, so it is *not* a per-build zc dependency. Committing a vendored zjs artifact (for clean-clone / CI / shipping) is deferred until a zc-less machine actually needs it — a second dev/CI host, the prod-packaging cycle, or gap #7's full zc removal. See `docs/superpowers/specs/2026-06-18-de-zc-build-design.md` ("Piece B — deferred"). |
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
- ~~#502~~ ✅ CLOSED by gap #2 Piece A — the `worker_service.nim` `{.emit.}` JsonValue struct mirror is gone; the ABI is `native/nim/jsonvalue.nim`.
- ~~#503~~ ✅ CLOSED by gap #2 Piece A — there is no longer a `zjson_provider.o`, so the hardcoded `$HOME`-absolute `passL` path (in two test files) is gone.
- #495 — iOS native `setInspectable` ignores the inspectable cascade (`ios/window.m:341`) — folds into gap #5 (iOS).
- #504 (done as nim-only) — zc worker async-invoke parity is the inverse direction (zc catching up); not on the replacement path.

## Uncertainty flags (from the 2026-06-18 read-only assessment)
- Not every leaf-service `.nim` was diffed against its `.zc` for sub-feature
  parity beyond the self-documented deferrals — small per-service gaps may exist.
- Whether `createProductionBundle`/`createDevBundle` succeed end-to-end on a Nim
  binary is inferred from shared orchestration, not a packaging run.
