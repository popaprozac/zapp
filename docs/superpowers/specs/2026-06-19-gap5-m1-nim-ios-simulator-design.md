# Gap #5 / M1 — Nim build on the iOS Simulator — design

**Date:** 2026-06-19
**Branch:** `feat/nim-native`
**Roadmap:** gap #5 of `docs/nim-migration-roadmap.md` ("iOS") — first milestone (M1)
**Status:** approved, ready for implementation plan

## Background

The **zc build already supports iOS** (production-ready): target detection
(`native.ts` `detectTarget`/`isIOSTarget`, `BuildTarget = macos | ios-simulator
| ios-device | windows`), SDK+arch+clang flags via `xcrun` (`build-config.ts`
~768-817), the 18 `native/platform/ios/*.m` (same `darwin_*` symbol names as
`darwin/*.m` so the shared framework layer binds unchanged), the
`_zapp_build_ios.zc` twin, the `ios-platform-parity.test.ts` gate, a prebuilt
`vendor/zjs/build/ios/simulator-arm64/libzjs_embed.a`, and the iOS dev-bundle +
`xcrun simctl` install/launch flow.

The **Nim build (`buildNativeNim` + `native/nim/zapp.nim`) is macOS-only**: it
hardcodes `platform:"macos"` (`native.ts` ~1140), the macOS framework set + the
`darwin/*.m` `{.compile.}` list + `libzjs.dylib` (`zapp.nim` ~12,18-34,190-196),
and passes no iOS SDK flags to `nim c`. Gap #5 brings the Nim build to iOS
parity; this milestone (M1) is the first, smallest slice.

### Decomposition (gap #5)

| Milestone | Scope |
|---|---|
| **M1 (this spec)** | kitchen-sink Nim → **iOS Simulator** (arm64): launches via the existing dev-bundle + `simctl` flow |
| M2 | iOS **device** (iphoneos SDK, code-signing / provisioning) |
| M3 | bare-engine iOS — **deferred** (worker-engine strategy: zjs is the default; bare backlogged) |
| M4 | App-Store packaging (`.ipa`, entitlements, notarization) |
| M5 | default-flip + zc removal |

M1 is **Simulator-only, launch gate.** Out of scope: device/signing (M2),
distribution packaging (M4), bare (M3), default-flip (M5).

## Goal

`ZAPP_NATIVE_LANG=nim bun run dev --platform ios` builds kitchen-sink for the
iOS Simulator (arm64) on the Nim path and launches it — webview renders, the
zjs worker runs (jitless). Reuses the zc path's iOS infra; the Nim build only
needs to become target-aware and emit an iOS-sim arm64 binary.

## Approach — CLI-generated `zapp_platform.nim`

The iOS SDK flags (`-isysroot <sdk>`, `-target arm64-apple-ios*-simulator`,
`-mios-simulator-version-min=…`) are absolute + machine-specific, so they **must**
come from the CLI (`xcrun`) regardless of approach. The design choice is only
*where the per-platform `{.compile.}` list + frameworks + libzjs path live*:

**Chosen: the CLI generates a per-target `zapp_platform.nim`** that carries the
resolved `{.compile.}` set (darwin vs ios `.m`), the framework set, and the
libzjs path; `zapp.nim` drops its hardcoded darwin pragmas and consumes it. This
matches the existing codegen pattern (`zapp_build_config.nim` /
`zapp_bootstrap.nim` / `zapp_assets.nim` / `nim.cfg`) and the zc path's
`generatePlatformConfig`, centralizes everything the CLI already resolves, and
**adapts to the spike's finding** about flag threading: if the iOS SDK flags
must be baked into each `{.compile.}` per-file flag string (rather than reaching
the `.m` files via a global `--passC`), the generator simply emits them per
pragma — no hand-editing of `zapp.nim`.

Rejected: `when defined(zappIos)` conditionals inline in `zapp.nim` — forks the
hand-written file, duplicates the `.m` lists, less consistent with the codebase.

## Components

### 1. Risk-gate spike (FIRST — gate before the rest)

The #1 unknown: can `nim c --cc:clang` cross-compile **both** the Nim-generated C
**and** the `{.compile.}`'d ObjC `.m` files to the iOS-sim SDK?

- Minimal `test.nim` + one `{.compile.}`'d `.m` that calls a UIKit symbol,
  compiled with `nim c --cc:clang` + iOS-sim SDK flags. **Success:** produces an
  `arm64-apple-ios*-simulator` Mach-O that links.
- **Determines the key design input:** do global `--passC "-isysroot …"` flags
  reach the `{.compile.}`'d `.m` files, or must the SDK flags be baked into each
  per-file `{.compile.}` flag string? (This shapes what the generator in
  component 3 emits.)
- Second half: link a trivial Nim iOS binary against the prebuilt
  `libzjs_embed.a` → **no duplicate-symbol errors** (the archive was already
  `ld -r` + `objcopy`-localized by the zc flow; M1 reuses it as-is, does **not**
  re-repack).
- **GATE:** if either half fails and can't be resolved by adjusting flags,
  STOP and report — do not proceed to the wiring. (Mirrors the NimSkel T1 /
  NimApp T2 / NimPerf T1 risk-gate pattern.)

### 2. `buildNativeNim` target-threading (`cli/src/native.ts`)

- Add `target: BuildTarget` to `buildNativeNim` (threaded from `compileNative`'s
  existing target detection at the call site).
- Permissions manifest: `platform: isIOSTarget(target) ? "ios" : "macos"`
  (replaces the hardcoded `"macos"`).
- iOS SDK resolution: reuse the existing `xcrun --sdk iphonesimulator
  --show-sdk-path` helper (the zc path's `resolveSDKPath`); pass the resulting
  flags into the `nim c` args and/or the generated pragmas per the spike outcome.
- macOS path unchanged (target `macos` keeps today's behavior exactly).

### 3. Generated `zapp_platform.nim` (renderer in `cli/src/build-config.ts`, bun-tested)

A pure renderer `renderPlatformNim(target, {…})` returning the Nim source, plus
the `buildNativeNim` wiring that writes it to `.zapp/` and ensures it's on the
`--path`. It emits, per target:

| Concern | macОS | iOS Simulator |
|---|---|---|
| `{.compile.}` sources | `../platform/darwin/*.m` (18) | `../platform/ios/*.m` (18, same names) |
| frameworks | Cocoa, WebKit, CoreFoundation, JavaScriptCore, Security, IOKit, ServiceManagement, UserNotifications, Carbon, Foundation | UIKit, Foundation, WebKit, JavaScriptCore, UserNotifications, UniformTypeIdentifiers, Security |
| libs | `-lcompression` | `-lcompression`, `-lz` |
| libzjs | `vendor/zjs/build/libzjs.dylib` + rpath | `vendor/zjs/build/ios/simulator-arm64/libzjs_embed.a` (static, no rpath) |
| per-`.m` clang flags | `-fobjc-arc` | `-fobjc-arc` + iOS SDK flags *if* the spike shows global `--passC` doesn't reach `{.compile.}` files |

`zapp.nim` drops its hardcoded darwin `{.compile.}`/framework/libzjs pragmas
(lines ~12,18-34,190-198) and imports/includes the generated module. The zjs.c
`{.compile.}` + its include path stay (shared engine glue), but its libzjs link
flag moves into the generated per-target module.

### 4. Reuse the iOS dev-bundle + `simctl` launch

No new packaging. The existing zc-path iOS dev flow (dev `.app` bundle +
`xcrun simctl install`/`launch`, already used by `bun run dev --platform ios`)
consumes the Nim-produced iOS binary. M1 confirms the Nim binary drops into that
flow unchanged.

### 5. Parity-gate verification (`cli/src/ios-platform-parity.test.ts`)

The test currently scans `.zc` for `darwin_*` references and asserts each is
defined in `ios/*.m`. The Nim build references the same `darwin_*` symbols via
`importc` in `.nim` files. Confirm the gate still covers the symbols the Nim
build needs; **extend it to also scan `native/nim/*.nim` `importc` declarations**
if any Nim-referenced `darwin_*` symbol isn't already covered by a `.zc`
reference. (Cheap insurance against an iOS link failure from a missing `ios/*.m`
definition.)

## Testing

- **Spike** (component 1) — the risk gate; both halves must pass.
- **bun-test** the `renderPlatformNim` renderer: asserts the darwin vs
  ios-simulator outputs (source list, frameworks, libzjs path) — same style as
  the existing `build-config` renderer tests.
- **Parity test** green (extended for the Nim path if needed).
- **Build gate:** `ZAPP_NATIVE_LANG=nim` macOS build still completes with
  `[zapp] build complete: …` (no regression), and the iOS-sim build produces an
  `arm64-apple-ios*-simulator` Mach-O (verify with `file`/`lipo -info`).
- **Human Sim smoke (the real proof):** `ZAPP_NATIVE_LANG=nim bun run dev
  --platform ios` → kitchen-sink installs + launches on the Simulator; webview
  renders; the gap-#3 `window:resize`→worker log fires on iOS (zjs jitless).
- `bun test` + `bunx tsc --noEmit` green.

## macOS → iOS hardcode map (what M1 generalizes)

| Location | Current (macOS-only) | iOS generalization |
|---|---|---|
| `native.ts` ~1140 | `platform: "macos"` | `isIOSTarget(target) ? "ios" : "macos"` |
| `native.ts` ~1237-1242 | no SDK/arch flags in `nim c` | thread `-isysroot`/`-target`/`-m*-version-min` (per spike) |
| `zapp.nim` ~12 | macOS frameworks (Cocoa…Carbon) | generated per-target framework set |
| `zapp.nim` ~18-34 | `../platform/darwin/*.m` | generated darwin-vs-ios `{.compile.}` list |
| `zapp.nim` ~196-198 | `libzjs.dylib` + rpath | generated: `libzjs_embed.a` (iOS) / `.dylib` (macOS) |

## libzjs iOS story

`vendor/zjs/build/ios/simulator-arm64/libzjs_embed.a` already exists (prebuilt by
the zc flow: `ld -r` merge + `objcopy` to localize zenc-stdlib internals and
keep only `_zjs_*` global, avoiding the duplicate-symbol collision with Zapp's
own stdlib copy). M1 **links it as-is** — no re-repack. `-lcompression` is valid
on both platforms; `libcompression`-based asset brotli-decode is
platform-agnostic.

## Out of scope (later milestones / deferred)

- iOS **device** + code-signing / provisioning (M2).
- Distribution **packaging** (`.ipa`, entitlements, notarization) (M4).
- **bare** engines on iOS (M3) — deferred per the worker-engine strategy.
- **default-flip + zc removal** (M5); the default-`app.nim` synthesis for
  entry-less pure-TS apps folds in there too.
- Regenerating `libzjs_embed.a` — reuse the prebuilt artifact.

## Risks

- **Nim→iOS cross-compile** (the #1 risk) — isolated to the component-1 spike;
  the generator adapts to its finding (global `--passC` vs per-`.m` flags).
- **`libzjs_embed.a` symbol visibility** under the Nim linker — gated by the
  spike's second half.
- **`ios/*.m` completeness** — the parity test is ~90%; any gap surfaces at link
  and is a small `ios/*.m` stub fill (in scope if it blocks the launch).
- **No macOS regression** — the macOS target path is unchanged by construction
  (generator emits today's pragmas for `macos`); guarded by the macOS build gate.
