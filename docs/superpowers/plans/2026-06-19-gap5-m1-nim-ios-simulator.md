# Gap #5 / M1 — Nim build on the iOS Simulator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `ZAPP_NATIVE_LANG=nim bun run dev --platform ios` builds kitchen-sink for the iOS Simulator (arm64) on the Nim path and launches it.

**Architecture:** Make the Nim build target-aware, reusing the zc path's iOS infra (`ios/*.m`, prebuilt `libzjs_embed.a`, `xcrun` SDK flags, dev-bundle + `simctl`). The per-platform `{.compile.}` list + frameworks + libzjs path move into a CLI-generated `zapp_platform.nim`; `zapp.nim` drops its hardcoded darwin pragmas. A risk-gate spike runs FIRST and determines how iOS SDK flags thread (global `--passC` vs per-`{.compile.}`-file).

**Tech Stack:** Nim (`nim c --cc:clang`, ORC, ObjC via `{.compile.}`), TypeScript (Bun CLI, `bun:test`), clang/`xcrun` iOS SDK, `xcrun simctl`.

**Spec:** `docs/superpowers/specs/2026-06-19-gap5-m1-nim-ios-simulator-design.md`.

**Scope:** Simulator-only launch gate. OUT: device/signing (M2), distribution packaging (M4), bare engines (M3), default-flip (M5).

**Key facts (from exploration):**
- `cli/src/native.ts`: `BuildTarget = "macos" | "ios-simulator" | "ios-device" | "windows"`; `detectTarget()` / `isIOSTarget()`; `buildNativeNim` ~line 1101; `compileNative` does target detection (~1247) and calls `buildNativeNim` (~1257); the `nim c` arg array ~1237-1242; hardcoded `platform:"macos"` ~1140.
- `cli/src/build-config.ts`: zc path's SDK resolver (`resolveSDKPath` / `xcrun --sdk <sdk> --show-sdk-path`, ~779); iOS clang flags `-arch arm64 -isysroot <sdk> -mios-simulator-version-min=15.0 -fobjc-arc` (~788); iOS frameworks UIKit/Foundation/WebKit/JavaScriptCore/UniformTypeIdentifiers/UserNotifications + `-lcompression -lz` (~794-811).
- `native/nim/zapp.nim`: macOS frameworks `{.passL.}` ~line 12; the 18 `{.compile("../platform/darwin/*.m","-fobjc-arc").}` ~18-34; `zjs.c` `{.compile.}` + include ~191-194; `libzjs.dylib` `{.passL.}` + rpath ~196-198.
- `getPlatformSources(nativeDir, target)` (native.ts ~47-133) already returns the right `.m` set per target (darwin vs ios) for the zc path — reuse it for the Nim source list.
- libzjs iOS artifact (prebuilt, reuse as-is): `vendor/zjs/build/ios/simulator-arm64/libzjs_embed.a`.
- `cli/src/ios-platform-parity.test.ts` guards `darwin_*` symbol parity (scans `.zc`).

---

## File Structure

- **Create (scratch, not committed)** `/tmp/zapp-ios-spike/*` — the risk-gate spike.
- **Modify** `cli/src/native.ts` — `buildNativeNim(target)` threading, platform manifest, SDK resolution, write the generated platform module, thread SDK flags.
- **Modify** `cli/src/build-config.ts` — `renderPlatformNim(target, opts)` renderer (the per-target `{.compile.}`/frameworks/libzjs pragmas).
- **Create** `cli/src/build-config.test.ts` additions (or a focused test file) — unit-test `renderPlatformNim`.
- **Modify** `native/nim/zapp.nim` — drop hardcoded darwin pragmas; consume the generated `zapp_platform` module.
- **Modify** `cli/src/ios-platform-parity.test.ts` — extend to cover `.nim` `importc` refs if needed.
- (Possibly) **Modify** `native/platform/ios/*.m` — fill any stub a link surfaces (only if it blocks M1).

---

### Task 1: RISK-GATE spike — Nim + ObjC → iOS-sim cross-compile + libzjs_embed link

No repo changes (scratch in `/tmp`). This gate determines the flag-threading approach used in Task 3. **Do not proceed to Task 2 until both halves pass (or report BLOCKED).**

**Files:**
- Create (scratch): `/tmp/zapp-ios-spike/test.nim`, `/tmp/zapp-ios-spike/uikit_probe.m`

- [ ] **Step 1: Resolve the iOS-sim SDK path.**

Run: `xcrun --sdk iphonesimulator --show-sdk-path`
Expected: a path like `/Applications/Xcode.app/.../iPhoneSimulator.sdk`. Save it as `$SDK`.

- [ ] **Step 2: Write a minimal Nim + ObjC iOS probe.**

`/tmp/zapp-ios-spike/uikit_probe.m`:
```objc
#import <UIKit/UIKit.h>
// Touch a UIKit symbol so the link must resolve the iOS framework.
int zapp_spike_uikit_probe(void) {
    return (int)[UIScreen mainScreen].scale; // any UIKit call
}
```

`/tmp/zapp-ios-spike/test.nim`:
```nim
{.compile: "uikit_probe.m".}
proc zapp_spike_uikit_probe(): cint {.importc, cdecl.}
echo "scale*=", zapp_spike_uikit_probe()
```

- [ ] **Step 3: Cross-compile to the iOS Simulator — global `--passC` variant.**

Run (substitute `$SDK`):
```bash
cd /tmp/zapp-ios-spike
nim c --cc:clang --mm:orc --threads:on --compileOnly:off \
  --passC:"-isysroot $SDK -target arm64-apple-ios15.0-simulator -fobjc-arc" \
  --passL:"-isysroot $SDK -target arm64-apple-ios15.0-simulator -framework UIKit -framework Foundation" \
  -o:/tmp/zapp-ios-spike/probe test.nim
```
Expected: builds. Then check the artifact:
```bash
file /tmp/zapp-ios-spike/probe   # should report arm64 ... (iOS) / Mach-O arm64
lipo -info /tmp/zapp-ios-spike/probe
```
**KEY OBSERVATION:** does the `{.compile.}`'d `uikit_probe.m` get the `-isysroot`/`-target` flags from the global `--passC`? Inspect the nim build output (or add `--listCmd`) to see the clang command for `uikit_probe.m`. If it compiles for iOS → **global `--passC` reaches `.m` files** (Task 3 threads SDK flags via `nim c` args). If `uikit_probe.m` compiles for the host (macOS) or the link fails → SDK flags must be **per-file**.

- [ ] **Step 4 (only if Step 3 showed per-file is required): per-file `{.compile.}` flag variant.**

Edit `test.nim`:
```nim
{.compile: ("uikit_probe.m", "-isysroot SDK_PLACEHOLDER -target arm64-apple-ios15.0-simulator -fobjc-arc").}
```
(substitute the real `$SDK`), rebuild with the same `nim c` line. Record which variant works. This decides what `renderPlatformNim` emits in Task 3.

- [ ] **Step 5: libzjs_embed link check.**

Add to `test.nim` a reference to a `zjs_*` symbol (e.g. `proc zjs_version(): cstring {.importc, cdecl.}` if it exists — check `vendor/zjs/include/zjs.h` for a trivial exported fn) and link against the prebuilt archive:
```bash
nim c --cc:clang --mm:orc --threads:on \
  --passC:"-isysroot $SDK -target arm64-apple-ios15.0-simulator -I /Users/zach/code/zapp/vendor/zjs/include" \
  --passL:"-isysroot $SDK -target arm64-apple-ios15.0-simulator -framework UIKit -framework Foundation -framework Security /Users/zach/code/zapp/vendor/zjs/build/ios/simulator-arm64/libzjs_embed.a" \
  -o:/tmp/zapp-ios-spike/probe2 test.nim
```
Expected: links with **no duplicate-symbol errors** (the archive is pre-localized). If a trivial `zjs_*` fn is hard to find, a bare link (no `zjs_*` reference, archive on the link line) still surfaces duplicate-symbol errors if present — that alone is a useful signal.

- [ ] **Step 6: GATE — record the finding, decide go/no-go.**

Report: (a) which flag-threading variant works (global `--passC` vs per-file `{.compile.}`), (b) that the iOS-sim Mach-O is produced (`file` output), (c) libzjs_embed links cleanly. If a half fails irrecoverably, STOP and report BLOCKED with the exact error + diagnosis (do NOT start Task 2). No commit — this is a gate; the finding feeds Task 3.

---

### Task 2: `buildNativeNim` target-threading + platform manifest

Makes the Nim build target-aware without changing macOS behavior. The SDK resolution + flag threading land here but are only exercised on iOS targets.

**Files:**
- Modify: `cli/src/native.ts`
- Test: `cli/src/build-config-nim.test.ts` (the existing Nim-codegen test file)

- [ ] **Step 1: Write the failing test** for the platform manifest field. In `cli/src/build-config-nim.test.ts`, add a test that `renderBuildConfigNim` (or whichever emitter writes the permissions manifest `platform`) emits `"ios"` when given an iOS target and `"macos"` otherwise. (Read the current emitter to find the exact function + how `platform` is currently set to `"macos"`; mirror the existing test style in that file.)

Run: `cd /Users/zach/code/zapp && bun test cli/src/build-config-nim.test.ts` → FAIL (platform currently hardcoded `"macos"`).

- [ ] **Step 2: Thread `target` + set the platform manifest.**
- Add `target: BuildTarget` to `buildNativeNim`'s options/signature (read the current signature ~native.ts:1101).
- At the `compileNative` call site (~1257), pass the already-detected `target`.
- Replace the hardcoded `platform: "macos"` (~1140) with `platform: isIOSTarget(target) ? "ios" : "macos"` (import/`use isIOSTarget` — it's already in this file).

- [ ] **Step 3: Resolve the iOS SDK path (iOS targets only).** In `buildNativeNim`, when `isIOSTarget(target)`, resolve the SDK via the existing zc-path helper (`resolveSDKPath`/`xcrun`; read `build-config.ts` ~779 for the exact export) and the version-min + arch flags. Store the resolved iOS clang/link flag strings for Task 3's generator + the `nim c` args. For `macos`, no SDK flags (unchanged).

- [ ] **Step 4: Run the test to verify it passes** + macOS build unaffected.

Run:
```bash
cd /Users/zach/code/zapp && bun test cli/src/build-config-nim.test.ts && bunx tsc --noEmit
cd kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build   # macOS — must still end with "[zapp] build complete"
```
Expected: test green; tsc clean; macOS Nim build completes (this proves the target param defaults to macOS behavior).

- [ ] **Step 5: Commit.**

```bash
cd /Users/zach/code/zapp
git add cli/src/native.ts cli/src/build-config-nim.test.ts
git commit -m "feat(cli): buildNativeNim is target-aware (platform manifest + iOS SDK resolution)

Threads BuildTarget into buildNativeNim; permissions manifest platform is
ios|macos; iOS targets resolve the simulator SDK path/flags via xcrun. macOS
behavior unchanged (target defaults to today's path).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: `renderPlatformNim` generator + `zapp.nim` de-hardcode (atomic cutover)

The per-platform pragmas move from hardcoded `zapp.nim` into a CLI-generated `zapp_platform.nim`. macOS MUST stay green (generator emits today's macOS pragmas for the `macos` target). Use the Task-1 finding for SDK-flag placement.

**Files:**
- Modify: `cli/src/build-config.ts` (add `renderPlatformNim`)
- Test: `cli/src/build-config-nim.test.ts`
- Modify: `cli/src/native.ts` (write the generated module, ensure on `--path`)
- Modify: `native/nim/zapp.nim` (drop hardcoded darwin pragmas; consume generated module)

- [ ] **Step 1: Write the failing renderer test.** In `cli/src/build-config-nim.test.ts`, add tests for `renderPlatformNim`:
  - `macos`: output contains `{.compile("../platform/darwin/platform.m"` (and the other darwin sources), the macOS framework `{.passL.}` (Cocoa…Carbon), and the `libzjs.dylib` passL + rpath.
  - `ios-simulator`: output contains `{.compile(` with `../platform/ios/` sources, the iOS framework set (`-framework UIKit`, no Cocoa/Carbon), and `vendor/zjs/build/ios/simulator-arm64/libzjs_embed.a` (no rpath).

Run: `bun test cli/src/build-config-nim.test.ts` → FAIL (`renderPlatformNim` undefined).

- [ ] **Step 2: Implement `renderPlatformNim(target, opts)`.** A pure function returning Nim source. Source list comes from `getPlatformSources(nativeDir, target)` (reuse). Per-target frameworks/libs/libzjs per the spec table. SDK-flag placement per the Task-1 finding:
  - If global `--passC` reaches `.m` files → emit `{.compile("<src>", "-fobjc-arc").}` (SDK flags go on the `nim c` line in Step 4).
  - If per-file required → emit `{.compile("<src>", "-fobjc-arc <iOS SDK flags>").}`.
Keep `zjs.c`'s `{.compile.}` + include path in the generated module too (it's per-target only in its libzjs link, which moves here). Paths absolute or `currentSourcePath`-relative as the existing pragmas are.

Example shape (macos branch):
```ts
// for target "macos": darwin sources + macOS frameworks + libzjs.dylib(+rpath)
// for target "ios-simulator": ios sources + UIKit set + libzjs_embed.a
```

- [ ] **Step 3: Run the renderer test → PASS.** `bun test cli/src/build-config-nim.test.ts`.

- [ ] **Step 4: Wire generation + de-hardcode `zapp.nim`.**
- In `buildNativeNim`, write `renderPlatformNim(target, …)` to `<zappDir>/zapp_platform.nim` (the `.zapp` dir already on `--path:${zappDir}`); if the spike said global flags, add the iOS SDK `--passC`/`--passL` to the `nim c` args array (~1237-1242) for iOS targets.
- In `native/nim/zapp.nim`: remove the hardcoded macOS framework `{.passL.}` (~12), the 18 darwin `{.compile.}` (~18-34), and the `libzjs.dylib` `{.passL.}`+rpath (~196-198). Add `import zapp_platform` (UnusedImport-suppressed, matching how `zapp_assets`/`zapp_build_config` are imported) so its pragmas are in the compile graph. Keep everything else (the std/os import, the zjs.c compile if not moved, the worker stubs, etc.).

- [ ] **Step 5: macOS build gate (no regression).**

Run: `cd kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build`
Expected: `[zapp] build complete: …` — proves the generated macOS pragmas reproduce today's build exactly. If a symbol/framework is missing, the generator's macOS branch is incomplete — fix to match the old `zapp.nim` pragmas verbatim.

- [ ] **Step 6: tsc + tests.**

Run: `cd /Users/zach/code/zapp && bunx tsc --noEmit && bun test`
Expected: green.

- [ ] **Step 7: Commit.**

```bash
cd /Users/zach/code/zapp
git add cli/src/build-config.ts cli/src/build-config-nim.test.ts cli/src/native.ts native/nim/zapp.nim
git commit -m "feat(cli): per-target zapp_platform.nim — Nim build sources/frameworks/libzjs by target

Generates .zapp/zapp_platform.nim (darwin vs ios .m, macOS vs UIKit frameworks,
libzjs.dylib vs libzjs_embed.a); zapp.nim drops its hardcoded darwin pragmas and
consumes it. macOS build unchanged (generator reproduces today's pragmas).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: iOS-sim build gate + parity test + human smoke

**Files:**
- Modify: `cli/src/ios-platform-parity.test.ts` (extend if needed)
- Possibly: `native/platform/ios/*.m` (only if a link gap blocks the launch)

- [ ] **Step 1: iOS-sim build produces an arm64 Mach-O.**

Run: `cd kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build --platform ios` (or the dev path — match how the zc iOS build is invoked; read the CLI). Expected: `[zapp] build complete: …`. Then verify the binary:
```bash
file kitchen-sink/<output-binary>   # Mach-O arm64 ... (iOS) / iOS Simulator
lipo -info kitchen-sink/<output-binary>
```
If the link fails on a missing `darwin_*` symbol, it's an `ios/*.m` gap — fill the minimal stub in `native/platform/ios/<file>.m` to match the darwin signature (return a sane default), then rebuild.

- [ ] **Step 2: Parity test — verify/extend.**

Run: `bun test cli/src/ios-platform-parity.test.ts` → green. If Step 1 surfaced a Nim-referenced `darwin_*` symbol the `.zc`-scanning test didn't catch, extend the test to also scan `native/nim/*.nim` `importc` declarations for `darwin_*` and assert ios/*.m coverage. Add a test asserting the extension works.

- [ ] **Step 3: Commit (if any parity/stub changes).**

```bash
cd /Users/zach/code/zapp
git add cli/src/ios-platform-parity.test.ts native/platform/ios/   # whatever changed
git commit -m "test(ios): extend platform-parity to the Nim importc surface + fill M1 ios stubs

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 4: Human Simulator smoke (GATE — the real proof).**

`ZAPP_NATIVE_LANG=nim bun run dev --platform ios` → kitchen-sink installs + launches on the iOS Simulator; webview renders; the gap-#3 `window:resize`→worker log fires (zjs jitless on iOS). This is a human step — pause for the user.

---

## After all tasks

- **Final cross-impl review** (subagent): the generator's macOS branch reproduces the old `zapp.nim` pragmas exactly (no macOS regression); the iOS branch matches the zc path's iOS flags/frameworks/libzjs; SDK-flag placement matches the Task-1 finding; no `.zc`/zc-path changes (this is Nim-path only); `zjs.c` untouched.
- **Roadmap:** mark gap #5 M1 done (Sim build path landed); M2 (device/signing) next.
- **Parked:** the human Sim smoke; subsequent milestones M2-M5.

## Self-Review notes (author)

- **Spec coverage:** risk-gate spike (Task 1), target-threading + manifest (Task 2), generator + de-hardcode (Task 3), iOS build + parity + smoke (Task 4). All M1 spec components mapped.
- **The one spike-dependent variable** (SDK-flag global-vs-per-file) is explicitly resolved by Task 1 and consumed by Task 3 — not left vague.
- **macOS no-regression** is gated at Task 2 Step 4 and Task 3 Step 5 (generator must reproduce today's pragmas).
- **Reuse, not rebuild:** `getPlatformSources`, `resolveSDKPath`, prebuilt `libzjs_embed.a`, the dev-bundle + `simctl` flow — all consumed, not reimplemented.
- **No placeholders:** spike + renderer are concrete; the per-file-flag branch is conditional on a stated finding, not a TODO.
