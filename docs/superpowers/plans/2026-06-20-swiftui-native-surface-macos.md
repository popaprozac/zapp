# SwiftUI native-surface primitive (macOS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a generic "native surface" pane to Zapp windows on macOS whose backing is SwiftUI (`NSHostingView`, enhanced) when available and AppKit (`NSView`, baseline) otherwise, with the `swiftc` step + Swift link flags wired into the real Nim build behind an opt-out gate.

**Architecture:** Framework-authored Swift in `native/platform/darwin/swift/` exposes an `@_cdecl` entry that returns an `NSHostingView`; `native/platform/darwin/nativesurface.m` resolves SwiftUI-vs-AppKit and attaches the view as a split pane; `buildNativeNim` compiles the Swift to a static lib and links it (gated by a pure, unit-tested decision function); a `nativeSurface` WindowOptions field triggers the pane; a button in either backing round-trips a value into Nim via an `exportc` symbol that emits a Zapp event observable from web content.

**Tech Stack:** Nim (`nim c --cc:clang --mm:orc`), Objective-C (AppKit), Swift (`swiftc -emit-library -static`), TypeScript CLI (Bun), bun:test. macOS-only this cycle.

**Branch:** `feat/nim-native` (do not merge to main). **Commit trailer (every commit):**
```
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

**Spec:** `docs/superpowers/specs/2026-06-20-swiftui-native-surface-macos-design.md`
**Reference (proven incantation):** `spikes/swiftui-nim/build.sh` + `spikes/swiftui-nim/FINDINGS.md`

---

## Verification model (read first)

This repo has **no native unit-test harness**. CLI/TS logic is verified with `bun:test` (true TDD). Native ObjC/Swift/Nim is verified by **build-succeeds + symbol-present + human visual smoke** — that is the established gate (see `docs/architecture.md` "Verifying native changes" and the `ios-platform-parity` test). So:

- **Tasks 1–2** (CLI/TS) are strict TDD: failing bun test → implement → green.
- **Tasks 3–8** (native) use build/symbol/smoke gates: each has an exact build command and an exact expected last line / `grep` / `otool`/`nm` check.

**The macOS "build complete" signal** (memory `feedback_verify_native_build`): a build is only successful when the LAST line is `[zapp] build complete: <path> (<size> KB)`. Vite's `✓ built in …` is NOT success.

**Build commands used throughout (run from `kitchen-sink/`):**
- macOS: `bun run build`
- iOS-sim: `bun run ../cli/src/zapp-cli.ts build --platform ios`

---

## File Structure

**Create:**
- `cli/src/swiftui-build.ts` — pure `resolveSwiftUIBuild()` decision function (no I/O).
- `cli/src/swiftui-build.test.ts` — bun unit tests for the decision function.
- `native/platform/darwin/swift/native_surface.swift` — framework Swift: `@_cdecl` returning an `NSHostingView`.
- `native/platform/darwin/nativesurface.m` — resolver (SwiftUI vs AppKit) + AppKit backing + window attach + chosen-backing report.
- `native/platform/ios/nativesurface.m` — iOS stubs (`darwin_native_surface_*`) so the shared Nim layer links on iOS.

**Modify:**
- `cli/src/config.ts` — add `swiftui?: boolean` to the `native?:` block (+ doc comment).
- `cli/src/native.ts` — `buildNativeNim`: run `swiftc` + append Swift link flags/defines (gated by `resolveSwiftUIBuild`); `getPlatformSources`: add `nativesurface.m` to the darwin + ios source lists.
- `native/nim/apptypes.nim` — add `nativeSurface: bool` to `WindowOptions` (+ default `false`).
- `native/nim/window.nim` — `wopts_native_surface` accessor; `darwin_native_surface_*` importc decls; `nativeSurfaceBacking()` getter; `zapp_native_surface_emit` exportc handler.
- `native/platform/darwin/window.m` — split builder: when `nativeSurface`, create + append the native-surface pane.
- `kitchen-sink/zapp/app.nim` — set `nativeSurface: true` on the main window (smoke).
- `kitchen-sink/src/main.ts` (or the existing web entry) — subscribe to the `native-surface:action` event (smoke).
- `docs/api-reference.md` — document the native-surface pane + `native.swiftui` opt-out + backing getter.

---

## Task 1: Config opt-out field `native.swiftui`

**Files:**
- Modify: `cli/src/config.ts` (the `native?:` block, ~line 756; `validateNative`, ~line 839)
- Test: `cli/src/config.test.ts` (or the existing native-config test file — search for `resolveNative` tests; if none, add to `cli/src/config.test.ts`)

- [ ] **Step 1: Find the existing native-config test file**

Run: `bun test cli/src 2>&1 | head -5` and `grep -rl "resolveNative\|validateNative" cli/src/*.test.ts`
Note the file that tests the `native:` block. Call it `<NATIVE_TEST>`. If none exists, create `cli/src/config.swiftui.test.ts` and import from `./config`.

- [ ] **Step 2: Write the failing test**

Add to `<NATIVE_TEST>` (adjust import to match the file's existing imports):

```ts
import { test, expect } from "bun:test";
import { validateNative } from "./config";

test("native.swiftui accepts a boolean and rejects non-boolean", () => {
  // valid: explicit opt-out
  expect(() => validateNative({ swiftui: false } as any)).not.toThrow();
  expect(() => validateNative({ swiftui: true } as any)).not.toThrow();
  // valid: omitted (default)
  expect(() => validateNative({} as any)).not.toThrow();
  // invalid: wrong type
  expect(() => validateNative({ swiftui: "yes" } as any)).toThrow(/swiftui/);
});
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bun test <NATIVE_TEST> -t swiftui`
Expected: FAIL (validateNative does not yet check `swiftui`; the `"yes"` case does not throw).

- [ ] **Step 4: Add the field + validation**

In `cli/src/config.ts`, in the `native?:` block (after `sources?: PlatformValue<string[]>;`):

```ts
    sources?: PlatformValue<string[]>;
    /**
     * Apple-only. Opt OUT of the SwiftUI "enhanced tier" for native surfaces.
     * Default (omitted/true): when the Swift toolchain is present, native
     * surfaces are backed by SwiftUI where its OS floor is met, falling back to
     * AppKit otherwise. Set `false` to force the AppKit baseline and skip the
     * `swiftc` build step entirely. No effect on Windows/Linux.
     */
    swiftui?: boolean;
```

In `validateNative`, after the existing `checkField(n.sources, "sources");` line, add:

```ts
  if (n.swiftui !== undefined && typeof n.swiftui !== "boolean") {
    throw new Error(`[zapp] native.swiftui must be a boolean, got ${typeof n.swiftui}`);
  }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bun test <NATIVE_TEST> -t swiftui`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add cli/src/config.ts <NATIVE_TEST>
git commit -m "feat(config): native.swiftui opt-out flag (Apple enhanced-tier gate)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 2: Pure build-decision function `resolveSwiftUIBuild`

**Files:**
- Create: `cli/src/swiftui-build.ts`
- Test: `cli/src/swiftui-build.test.ts`

This isolates the gating logic from the imperative build so it can be unit-tested without invoking `swiftc`.

- [ ] **Step 1: Write the failing test**

Create `cli/src/swiftui-build.test.ts`:

```ts
import { test, expect } from "bun:test";
import { resolveSwiftUIBuild } from "./swiftui-build";

const base = { swiftLibDir: "/proj/.zapp", swiftcAvailable: true, swiftuiConfig: undefined as boolean | undefined };

test("macOS + toolchain + default config → enabled with defines + link flags", () => {
  const p = resolveSwiftUIBuild({ ...base, target: "macos" });
  expect(p.enabled).toBe(true);
  expect(p.reason).toBe("enabled");
  expect(p.nimArgs).toContain("-d:zappSwiftUI");
  expect(p.nimArgs).toContain("--passC:-DZAPP_HAS_SWIFTUI");
  // load-bearing link bits (per FINDINGS): our static lib + swift runtime + rpath + SwiftUI
  const link = p.nimArgs.find((a) => a.startsWith("--passL:")) ?? "";
  expect(link).toContain("-lzappswift");
  expect(link).toContain("-lswiftCore");
  expect(link).toContain("-rpath");
  expect(link).toContain("/usr/lib/swift");
  expect(link).toContain("-framework SwiftUI");
  expect(link).toContain("/proj/.zapp"); // -L<swiftLibDir>
});

test("macOS + explicit opt-out → disabled, no swiftc, no defines", () => {
  const p = resolveSwiftUIBuild({ ...base, target: "macos", swiftuiConfig: false });
  expect(p.enabled).toBe(false);
  expect(p.reason).toBe("disabled-opt-out");
  expect(p.runSwiftc).toBe(false);
  expect(p.nimArgs).toEqual([]);
});

test("macOS but swiftc missing → disabled (skipped), no defines", () => {
  const p = resolveSwiftUIBuild({ ...base, target: "macos", swiftcAvailable: false });
  expect(p.enabled).toBe(false);
  expect(p.reason).toBe("skipped-no-swiftc");
  expect(p.runSwiftc).toBe(false);
  expect(p.nimArgs).toEqual([]);
});

test("iOS target → disabled (non-macos this cycle)", () => {
  const p = resolveSwiftUIBuild({ ...base, target: "ios-simulator" });
  expect(p.enabled).toBe(false);
  expect(p.reason).toBe("non-macos");
  expect(p.runSwiftc).toBe(false);
});

test("enabled implies runSwiftc true", () => {
  const p = resolveSwiftUIBuild({ ...base, target: "macos" });
  expect(p.runSwiftc).toBe(true);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test cli/src/swiftui-build.test.ts`
Expected: FAIL with "Cannot find module './swiftui-build'".

- [ ] **Step 3: Implement the decision function**

Create `cli/src/swiftui-build.ts`:

```ts
import type { BuildTarget } from "./native";

export interface SwiftUIBuildPlan {
  /** SwiftUI is compiled in for this build. */
  enabled: boolean;
  /** Whether buildNativeNim should run the swiftc step. */
  runSwiftc: boolean;
  /** Why (for the build log line). */
  reason: "enabled" | "disabled-opt-out" | "skipped-no-swiftc" | "non-macos";
  /** Extra `nim c` args to append when enabled (defines + passC + passL). Empty when disabled. */
  nimArgs: string[];
}

/**
 * Decide whether/how SwiftUI is compiled into this build. Pure — no I/O.
 * Apple enhanced-tier gate (macOS only this cycle):
 *   enabled  ⇔ target == macos AND swiftc present AND not opted out.
 * When enabled, emit the Nim defines + the proven Swift link flags
 * (see spikes/swiftui-nim/FINDINGS.md — the load-bearing pieces are the SDK
 * .tbd stubs for -lswiftCore/-lswiftFoundation plus -rpath /usr/lib/swift).
 */
export function resolveSwiftUIBuild(opts: {
  target: BuildTarget;
  swiftuiConfig: boolean | undefined; // config.native?.swiftui
  swiftcAvailable: boolean;
  swiftLibDir: string; // dir that will hold libzappswift.a (for -L)
}): SwiftUIBuildPlan {
  const { target, swiftuiConfig, swiftcAvailable, swiftLibDir } = opts;

  if (target !== "macos") return { enabled: false, runSwiftc: false, reason: "non-macos", nimArgs: [] };
  if (swiftuiConfig === false) return { enabled: false, runSwiftc: false, reason: "disabled-opt-out", nimArgs: [] };
  if (!swiftcAvailable) return { enabled: false, runSwiftc: false, reason: "skipped-no-swiftc", nimArgs: [] };

  // AppKit comes in via -framework Cocoa already; only add SwiftUI here.
  // Drop the cosmetic toolchain -rpath (FINDINGS): lean on SDK .tbd + /usr/lib/swift.
  const link =
    `-L${swiftLibDir} -lzappswift -lswiftCore -lswiftFoundation ` +
    `-Xlinker -rpath -Xlinker /usr/lib/swift -framework SwiftUI`;

  return {
    enabled: true,
    runSwiftc: true,
    reason: "enabled",
    nimArgs: ["-d:zappSwiftUI", "--passC:-DZAPP_HAS_SWIFTUI", `--passL:${link}`],
  };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bun test cli/src/swiftui-build.test.ts`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add cli/src/swiftui-build.ts cli/src/swiftui-build.test.ts
git commit -m "feat(cli): resolveSwiftUIBuild pure gating decision (macOS enhanced tier)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 3: Framework Swift layer — `native_surface.swift`

**Files:**
- Create: `native/platform/darwin/swift/native_surface.swift`

A self-contained Swift source `swiftc` can compile alone. It must NOT be picked up by the `.m` compile list (it lives in a `swift/` subdir; the darwin source list is explicit `.m` paths — verify in Task 5).

- [ ] **Step 1: Write the Swift source**

Create `native/platform/darwin/swift/native_surface.swift`:

```swift
// Framework-authored SwiftUI backing for Zapp's generic "native surface".
// Exposed to the ObjC resolver (nativesurface.m) via a plain C ABI (@_cdecl),
// exactly like the proven spike (spikes/swiftui-nim). The resolver decides
// SwiftUI-vs-AppKit; this file is only reached when SwiftUI is the choice.
import SwiftUI
import AppKit

// C callback the demonstrative control invokes to round-trip a value into Nim.
// (window_id, value) — value is a borrowed C string valid for the call only.
public typealias ZappSurfaceCallback = @convention(c) (Int32, UnsafePointer<CChar>?) -> Void

@available(macOS 10.15, *)
struct ZappNativeSurfaceView: View {
    let windowId: Int32
    let callback: ZappSurfaceCallback?
    @State private var taps = 0

    var body: some View {
        VStack(spacing: 12) {
            Text("SwiftUI native surface")
                .font(.headline)
            Text("taps: \(taps)")
                .foregroundColor(.secondary)
            Button("Ping Nim") {
                taps += 1
                "swiftui:\(taps)".withCString { callback?(windowId, $0) }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// Returns a retained NSView* (NSHostingView). The ObjC side owns it.
// nil if SwiftUI's floor isn't met at runtime (defensive; the resolver also checks).
@_cdecl("zapp_swift_native_surface_create")
public func zapp_swift_native_surface_create(_ windowId: Int32,
                                             _ callback: ZappSurfaceCallback?) -> UnsafeMutableRawPointer? {
    guard #available(macOS 10.15, *) else { return nil }
    let host = NSHostingView(rootView: ZappNativeSurfaceView(windowId: windowId, callback: callback))
    // Hand off a +1 reference to ObjC (which does CFBridgingRelease / __bridge_transfer).
    return Unmanaged.passRetained(host).toOpaque()
}
```

- [ ] **Step 2: Verify it compiles standalone**

Run:
```bash
cd native/platform/darwin/swift && swiftc -emit-library -static -O -module-name zappswift -o /tmp/libzappswift.a native_surface.swift && echo OK && cd -
```
Expected: prints `OK` (a `/tmp/libzappswift.a` is produced). Then `rm -f /tmp/libzappswift.a`.

- [ ] **Step 3: Commit**

```bash
git add native/platform/darwin/swift/native_surface.swift
git commit -m "feat(darwin): SwiftUI native-surface view (@_cdecl NSHostingView)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 4: ObjC resolver + AppKit backing + iOS stub

**Files:**
- Create: `native/platform/darwin/nativesurface.m`
- Create: `native/platform/ios/nativesurface.m`
- Modify: `cli/src/native.ts` (`getPlatformSources` — add `nativesurface.m` to darwin + ios lists)

`nativesurface.m` exposes `darwin_native_surface_create(window_id)` returning an `NSView*`, choosing SwiftUI (when `ZAPP_HAS_SWIFTUI` is defined + `@available` + window flag) or AppKit. The window-attach happens in Task 6 (window.m); here the function just builds + returns the view and records the backing. Both backings call the same Nim `exportc` `zapp_native_surface_emit` (declared here, defined in Task 5/6's Nim).

- [ ] **Step 1: Confirm how `getPlatformSources` lists `.m` files**

Run: `grep -n "getPlatformSources\|platform/darwin/\|platform/ios/\|\.m\"" cli/src/native.ts | head -30`
Confirm the darwin source list is an explicit array of `.m` paths (e.g. `"window.m"`, `"webview.m"`, …). The Swift file is in `swift/` so it is NOT in this list.

- [ ] **Step 2: Write `nativesurface.m` (darwin)**

Create `native/platform/darwin/nativesurface.m`:

```objc
// Generic "native surface" — resolves a SwiftUI (enhanced) or AppKit (baseline)
// backing and reports which one. Window attach lives in window.m's split builder.
#import <Cocoa/Cocoa.h>

// Nim-defined (exportc). Round-trips the demonstrative control's value into Nim,
// which emits a Zapp event observable from web content. Defined in window.nim.
extern void zapp_native_surface_emit(int32_t window_id, const char* value);

#ifdef ZAPP_HAS_SWIFTUI
// Swift @_cdecl entry (native_surface.swift). Returns a retained NSView* (+1).
typedef void (*ZappSurfaceCallback)(int32_t window_id, const char* value);
extern void* zapp_swift_native_surface_create(int32_t window_id, ZappSurfaceCallback cb);

// Trampoline so the Swift callback reaches Nim.
static void zapp_native_surface_cb(int32_t window_id, const char* value) {
    zapp_native_surface_emit(window_id, value);
}
#endif

// "swiftui" or "appkit" — last resolved backing for the given window. Simple
// single-slot cache is enough for the primitive (one native surface per window).
static NSMutableDictionary<NSNumber*, NSString*>* zapp_surface_backing(void) {
    static NSMutableDictionary* d = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [NSMutableDictionary dictionary]; });
    return d;
}

// AppKit baseline: a label + button wired to the same Nim emit.
@interface ZappAppKitSurface : NSView
@property (nonatomic, assign) int32_t windowId;
@property (nonatomic, assign) int32_t taps;
@property (nonatomic, strong) NSTextField* tapsLabel;
@end

@implementation ZappAppKitSurface
- (instancetype)initWithWindowId:(int32_t)wid {
    self = [super initWithFrame:NSZeroRect];
    if (!self) return nil;
    _windowId = wid;
    NSTextField* title = [NSTextField labelWithString:@"AppKit native surface"];
    title.font = [NSFont boldSystemFontOfSize:13];
    _tapsLabel = [NSTextField labelWithString:@"taps: 0"];
    _tapsLabel.textColor = [NSColor secondaryLabelColor];
    NSButton* btn = [NSButton buttonWithTitle:@"Ping Nim" target:self action:@selector(ping:)];
    NSStackView* stack = [NSStackView stackViewWithViews:@[title, _tapsLabel, btn]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.spacing = 12;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
    return self;
}
- (void)ping:(id)sender {
    (void)sender;
    self.taps += 1;
    self.tapsLabel.stringValue = [NSString stringWithFormat:@"taps: %d", self.taps];
    NSString* v = [NSString stringWithFormat:@"appkit:%d", self.taps];
    zapp_native_surface_emit(self.windowId, v.UTF8String);
}
@end

// Build the surface view for `window_id`, choosing the backing. Returns an
// autoreleased NSView*; window.m wraps it in a split item.
NSView* darwin_native_surface_create(int32_t window_id) {
    NSView* view = nil;
    NSString* backing = @"appkit";
#ifdef ZAPP_HAS_SWIFTUI
    if (@available(macOS 10.15, *)) {
        void* p = zapp_swift_native_surface_create(window_id, zapp_native_surface_cb);
        if (p) {
            view = (__bridge_transfer NSView*)p; // take the +1 from Swift
            backing = @"swiftui";
        }
    }
#endif
    if (!view) {
        view = [[ZappAppKitSurface alloc] initWithWindowId:window_id];
    }
    zapp_surface_backing()[@(window_id)] = backing;
    if (getenv("ZAPP_LOG")) {
        NSLog(@"[zapp] native surface backing: %@", backing);
    }
    return view;
}

// "swiftui" | "appkit" | "" (none yet). Caller copies immediately.
const char* darwin_native_surface_backing(int32_t window_id) {
    NSString* b = zapp_surface_backing()[@(window_id)];
    return b ? b.UTF8String : "";
}
```

- [ ] **Step 3: Write `nativesurface.m` (iOS stub)**

Create `native/platform/ios/nativesurface.m`:

```objc
// iOS stubs so the shared Nim layer (window.nim) links on iOS. SwiftUI on iOS
// is a future cycle; the native surface is a no-op here for now.
#import <Foundation/Foundation.h>
#import <stdint.h>

void* darwin_native_surface_create(int32_t window_id) { (void)window_id; return NULL; }
const char* darwin_native_surface_backing(int32_t window_id) { (void)window_id; return ""; }
```

- [ ] **Step 4: Register both sources in `getPlatformSources`**

In `cli/src/native.ts`, add `"nativesurface.m"` to the darwin `.m` list and the ios `.m` list (next to `inspector.m` / `sidebar.m` in each). Match the existing entry style exactly.

- [ ] **Step 5: Verify the macOS build still links (AppKit-only path; ZAPP_HAS_SWIFTUI not yet defined)**

Run: `cd kitchen-sink && bun run build 2>&1 | tail -3`
Expected last line: `[zapp] build complete: …/bin/kitchen-sink (… KB)`.
Then: `nm kitchen-sink/bin/kitchen-sink | grep -c "_darwin_native_surface_create"` → expect `1` (compiled in, AppKit path).

- [ ] **Step 6: Verify the iOS-sim build still links (stub present)**

Run: `cd kitchen-sink && bun run ../cli/src/zapp-cli.ts build --platform ios 2>&1 | tail -3`
Expected last line: `[zapp] build complete: …/bin/ios/kitchen-sink.app/kitchen-sink (… KB)`.

- [ ] **Step 7: Commit**

```bash
git add native/platform/darwin/nativesurface.m native/platform/ios/nativesurface.m cli/src/native.ts
git commit -m "feat(darwin): native-surface resolver + AppKit backing + iOS stub

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 5: Wire `swiftc` + Swift link flags into `buildNativeNim`

**Files:**
- Modify: `cli/src/native.ts` (`buildNativeNim`)

Compile the framework Swift to `<.zapp>/libzappswift.a` and append the gated nim args, using `resolveSwiftUIBuild` from Task 2. This defines `ZAPP_HAS_SWIFTUI` → activates the SwiftUI path in `nativesurface.m`.

- [ ] **Step 1: Add the swiftc step + gated args (before the `const args = [...]` assembly)**

In `buildNativeNim`, just before the `const args = ["c", …]` line (where `iosArgs` is already spread), insert:

```ts
  // SwiftUI enhanced tier (macOS only). Compile the framework's Swift sources to
  // a static lib, then append the gated nim args (defines + Swift link flags).
  // Decision is the pure resolveSwiftUIBuild (unit-tested); here we only do I/O.
  const { resolveSwiftUIBuild } = await import("./swiftui-build");
  const swiftcPath = Bun.which("swiftc");
  const swiftPlan = resolveSwiftUIBuild({
    target,
    swiftuiConfig: config.native?.swiftui,
    swiftcAvailable: !!swiftcPath,
    swiftLibDir: zappDir,
  });
  if (swiftPlan.runSwiftc) {
    const swiftSrcDir = path.join(nativeDir, "platform", "darwin", "swift");
    const swiftSrcs = (await fs.readdir(swiftSrcDir)).filter((f) => f.endsWith(".swift")).map((f) => path.join(swiftSrcDir, f));
    const swiftLib = path.join(zappDir, "libzappswift.a");
    const sc = Bun.spawnSync([
      "swiftc", "-emit-library", "-static", "-O", "-module-name", "zappswift",
      "-o", swiftLib, ...swiftSrcs,
    ]);
    if (sc.exitCode !== 0) {
      throw new Error(`[zapp] swiftc failed:\n${new TextDecoder().decode(sc.stderr)}`);
    }
  }
  clog(1, `SwiftUI: ${swiftPlan.reason === "enabled" ? "enabled (enhanced tier)" :
    swiftPlan.reason === "disabled-opt-out" ? "disabled (opt-out)" :
    swiftPlan.reason === "skipped-no-swiftc" ? "skipped (swiftc not found — AppKit baseline)" :
    "n/a (non-macOS)"}`);
```

Then add `...swiftPlan.nimArgs` to the `const args = [...]` array (next to `...iosArgs`):

```ts
  const args = ["c", "--cc:clang", "--mm:orc", "--threads:on", "-d:release", "--opt:size",
                `--path:${zappDir}`, `--path:${nimFrameworkDir}`,
                ...iosArgs,
                ...swiftPlan.nimArgs,
                `-o:${output}`, ...(verbose ? [] : ["--hints:off"]), nimRoot];
```

(`clog` is already imported in native.ts — verify with `grep -n "clog" cli/src/native.ts | head -1`; if not, import it from `./log`.)

- [ ] **Step 2: Verify macOS build links the Swift lib clean (enhanced path active)**

Run: `cd kitchen-sink && bun run build 2>&1 | tail -4`
Expected: a `[zapp] SwiftUI: enabled (enhanced tier)` line appears, and the last line is `[zapp] build complete: …`.

- [ ] **Step 3: Verify the Swift runtime is OS-provided (not bundled) + lib was built**

Run:
```bash
ls -la kitchen-sink/.zapp/libzappswift.a
otool -L kitchen-sink/bin/kitchen-sink | grep -i swift
```
Expected: `libzappswift.a` exists; `otool -L` shows `/usr/lib/swift/libswiftCore.dylib` (+ libswiftFoundation) — OS-provided, nothing bundled (matches FINDINGS).

- [ ] **Step 4: Verify the opt-out path links clean with no Swift**

Temporarily add `native: { swiftui: false }` to `kitchen-sink/zapp.config.ts`, then:
```bash
cd kitchen-sink && bun run build 2>&1 | tail -4
otool -L bin/kitchen-sink | grep -i swift || echo "NO-SWIFT-OK"
```
Expected: a `[zapp] SwiftUI: disabled (opt-out)` line; last line `build complete`; `otool` prints `NO-SWIFT-OK` (no swift dylib).
Then **revert** the `native: { swiftui: false }` edit (leave kitchen-sink default = enabled).

- [ ] **Step 5: Commit**

```bash
git add cli/src/native.ts
git commit -m "feat(cli): compile + link framework SwiftUI in buildNativeNim (gated)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 6: WindowOptions `nativeSurface` field + Nim wiring + split-builder attach

**Files:**
- Modify: `native/nim/apptypes.nim` (`WindowOptions` + its default constructor)
- Modify: `native/nim/window.nim` (`wopts_native_surface` accessor; `darwin_native_surface_*` importc; `nativeSurfaceBacking()` getter; `zapp_native_surface_emit` exportc)
- Modify: `native/platform/darwin/window.m` (split builder appends the native-surface pane)

This is Nim-only (the legacy `=zc` path is slated for deletion in cycle 7b; per `feedback_nim_zc_parity` this divergence is **surfaced explicitly here**, not added to `window.zc`).

- [ ] **Step 1: Add the field to `WindowOptions`**

In `native/nim/apptypes.nim`, find the `WindowOptions` object (it has `sidebarUrl`, `inspectorUrl`, etc.). Add:

```nim
    nativeSurface*: bool       ## macOS: attach a framework "native surface" pane
                               ## (SwiftUI enhanced / AppKit baseline). No-op off-Apple.
```

If `WindowOptions` has a default/`init` proc that sets fields, set `nativeSurface: false` there (bools default to false in Nim, so only needed if there's an explicit initializer — match the existing style for `inspectorCollapsed`).

- [ ] **Step 2: Add the `wopts` accessor + importc decls + getter + emit handler**

In `native/nim/window.nim`:

Near the other `wopts_*` accessors (e.g. after `wopts_inspector_*`), add a bool accessor (match how an existing bool flag is exposed — search `wopts_` for a `cint`/bool one like inspectorCollapsed; mirror it):

```nim
proc wopts_native_surface(p: pointer): cint {.exportc, cdecl.} =
  (if opt(p).nativeSurface: 1 else: 0).cint
```

Near the other `darwin_*` importc decls, add:

```nim
proc darwin_native_surface_backing(window_id: int32): cstring {.importc, cdecl.}
```

Add the public getter (near `show*`/`onReady*`):

```nim
proc nativeSurfaceBacking*(win: Window): string =
  ## macOS: which backing the native-surface pane resolved to — "swiftui",
  ## "appkit", or "" if the window has no native surface. Useful for DX/debug.
  $darwin_native_surface_backing(win.id.int32)
```

Add the round-trip emit handler (the C symbol `nativesurface.m` calls). Emit a Zapp event observable from web content — mirror how other native callbacks reach web content (search the codebase for the existing broadcast/emit helper used by Nim, e.g. `dispatchEventToAll` / `zapp_dispatch_event`; use the same one):

```nim
proc zapp_native_surface_emit(window_id: int32, value: cstring) {.exportc, cdecl.} =
  ## Called from nativesurface.m when the demonstrative control fires. Emits a
  ## "native-surface:action" event (detail = {value}) to all webviews so web
  ## content can observe the native→Nim round-trip.
  let v = if value.isNil: "" else: $value
  let detail = "{\"value\":\"" & v & "\"}"
  emitToWebviews("native-surface:action", detail)   # ← use the project's real emit helper
```

NOTE for implementer: replace `emitToWebviews(...)` with the actual helper this codebase uses to push an event from Nim to web content. Find it with:
`grep -rn "proc .*emit\|dispatchEventToAll\|broadcast" native/nim/*.nim | grep -i "webview\|event\|broadcast"`. Match its exact signature (event-name + JSON-detail string). Do not invent a new path.

- [ ] **Step 3: Append the pane in window.m's split builder**

In `native/platform/darwin/window.m`, find where the split builder adds the inspector / sidebar `NSSplitViewItem`s from the window options (search `NSSplitViewItem` and the `wopts_inspector`/`wopts_sidebar` reads). Add a parallel block, after the content (and inspector) item, gated on the new flag:

```objc
// Native surface pane (SwiftUI enhanced / AppKit baseline). Reuses the split.
extern NSView* darwin_native_surface_create(int32_t window_id);
extern int wopts_native_surface(void* opts);   // 1/0  (declare near other wopts_*)
...
if (wopts_native_surface(opts)) {
    NSView* surface = darwin_native_surface_create(numericWindowId); // the window's numeric id in scope
    NSViewController* vc = [[NSViewController alloc] init];
    vc.view = surface;
    NSSplitViewItem* item = [NSSplitViewItem splitViewItemWithViewController:vc];
    item.minimumThickness = 240;
    [splitVC addSplitViewItem:item];   // match the local split-view-controller variable name
}
```

Implementer: align variable names (`opts`, `numericWindowId`, `splitVC`) with the ones already used in that builder. If the builder uses `NSSplitView` directly rather than `NSSplitViewController`, attach via the same mechanism the inspector uses.

- [ ] **Step 4: Build + verify symbol wiring (macOS)**

Run: `cd kitchen-sink && bun run build 2>&1 | tail -3`
Expected last line: `build complete`.
Then: `nm kitchen-sink/bin/kitchen-sink | grep -E "_zapp_native_surface_emit|_darwin_native_surface_backing" | wc -l` → expect `2`.

- [ ] **Step 5: iOS-sim build still links (uses the stub)**

Run: `cd kitchen-sink && bun run ../cli/src/zapp-cli.ts build --platform ios 2>&1 | tail -3`
Expected last line: `build complete`.

- [ ] **Step 6: Commit**

```bash
git add native/nim/apptypes.nim native/nim/window.nim native/platform/darwin/window.m
git commit -m "feat(window): nativeSurface pane option + backing getter + round-trip emit (Nim)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 7: kitchen-sink smoke wiring

**Files:**
- Modify: `kitchen-sink/zapp/app.nim` (set `nativeSurface: true` on the main window)
- Modify: `kitchen-sink` web entry (subscribe to `native-surface:action`)

- [ ] **Step 1: Enable the pane on the main window**

In `kitchen-sink/zapp/app.nim`, the main `app.window.create(WindowOptions(…))` call already sets `sidebarUrl`/`inspectorUrl`. Add `nativeSurface: true` to that `WindowOptions(...)`:

```nim
  let win = app.window.create(WindowOptions(
    # …existing fields…
    nativeSurface: true,
  ))
```

- [ ] **Step 2: Subscribe to the round-trip event in web content**

Find the kitchen-sink web entry that already uses the Zapp events API (search `kitchen-sink/src` for `Events.on` / `addEventListener` / the runtime events import). Add a listener that logs/shows the value:

```ts
// kitchen-sink/src/main.ts (or the existing events setup file)
import { Events } from "@zappdev/runtime"; // ← match the actual import the app uses
Events.on("native-surface:action", (detail: any) => {
  console.log("[kitchen-sink] native surface →", detail?.value);
});
```

Implementer: match the app's existing events-API import/usage exactly (do not introduce a new events client).

- [ ] **Step 3: Build for the smoke**

Run: `cd kitchen-sink && bun run build 2>&1 | tail -3`
Expected last line: `build complete`.

- [ ] **Step 4: Commit**

```bash
git add kitchen-sink/zapp/app.nim kitchen-sink/src
git commit -m "test(kitchen-sink): native-surface pane + round-trip event subscriber

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 8: Docs + full gate + human visual smoke

**Files:**
- Modify: `docs/api-reference.md`

- [ ] **Step 1: Document the capability**

In `docs/api-reference.md`, add a short "Native surface (macOS)" subsection near the sidebar/inspector docs covering: the `nativeSurface` WindowOptions field, the SwiftUI-enhanced / AppKit-baseline resolution, `win.nativeSurfaceBacking()`, the `native.swiftui: false` opt-out, the `native-surface:action` event, and that it is macOS-only this cycle (iOS = future). Keep it consistent with the doc's existing style.

- [ ] **Step 2: Run the full automated gate**

```bash
bun test cli/src 2>&1 | tail -5
```
Expected: all pass (includes Tasks 1–2 + existing 97 + ios-platform-parity).

- [ ] **Step 3: Build gates — enabled, opted-out, iOS-sim**

```bash
# enabled (default)
cd kitchen-sink && bun run build 2>&1 | tail -2
otool -L bin/kitchen-sink | grep -i swiftcore && echo SWIFT-LINKED-OK
# opted-out
# (temporarily set native:{swiftui:false} in zapp.config.ts)
bun run build 2>&1 | tail -2 ; otool -L bin/kitchen-sink | grep -i swift || echo NO-SWIFT-OK
# (revert the opt-out edit)
# iOS-sim
bun run ../cli/src/zapp-cli.ts build --platform ios 2>&1 | tail -2
```
Expected: each ends in `build complete`; `SWIFT-LINKED-OK` when enabled; `NO-SWIFT-OK` when opted out.

- [ ] **Step 4: Human visual smoke (pause for the user)**

Build + run the macOS app (default, SwiftUI enabled):
```bash
cd kitchen-sink && bun run build && ./bin/kitchen-sink
```
Ask the user to confirm:
1. A **native-surface pane** appears in the window showing "SwiftUI native surface" + a "Ping Nim" button.
2. Clicking **Ping Nim** increments the taps label AND logs `[kitchen-sink] native surface → swiftui:N` in the web console (the native→Nim→web round-trip).
3. (Optional) Rebuild with `native: { swiftui: false }` → the same pane shows "AppKit native surface" and clicking logs `appkit:N`. Then revert.

Do NOT mark complete until the user confirms (1) and (2).

- [ ] **Step 5: Commit docs**

```bash
git add docs/api-reference.md
git commit -m "docs(api): native surface (macOS) — SwiftUI/AppKit backings + opt-out

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 6: Final cross-cutting review**

Re-read the diff for: (a) iOS stub parity (`darwin_native_surface_*` defined in `ios/`), (b) the opt-out path leaves zero Swift in the binary, (c) no `window.zc` change (Nim-only divergence is intentional + surfaced), (d) the Swift runtime is OS-provided (not bundled). Note any follow-ups in memory.

---

## Self-Review (against the spec)

**Spec coverage:**
- §2 build wiring → Tasks 2 (decision fn) + 5 (swiftc + link). ✓
- §2 defines `-d:zappSwiftUI` / `-DZAPP_HAS_SWIFTUI` → Task 2 (nimArgs) + 5 (applied). ✓
- §2 pure unit-testable decision → Task 2. ✓
- §3 Swift layer (`@_cdecl` NSHostingView + callback) → Task 3. ✓
- §3 ObjC resolver + AppKit backing + attach → Tasks 4 (resolver/backing) + 6 (attach). ✓
- §4 Nim `nativeSurface` option + `nativeSurfaceBacking` getter → Task 6. ✓
- §4 round-trip → Zapp event observable from web → Tasks 6 (emit) + 7 (subscribe). ✓
- §4 iOS stub for symbol parity → Task 4. ✓
- §5 opt-out (`native.swiftui:false`) + messaging + always-functional fallback → Tasks 1, 5, 4. ✓
- §6 testing: bun unit tests + macOS-enabled + macOS-opted-out + iOS-sim + visual smoke → Tasks 2, 5, 8. ✓
- Future work (iOS, app-authored, feature ports) → out of scope, not tasked (correct). ✓

**Placeholder scan:** Two deliberate "match the project's real helper" notes (the Nim emit helper in Task 6 Step 2; the events import in Task 7 Step 2) — these are real-codebase-lookup instructions with the exact `grep` to run, not vague TODOs, because the precise symbol must be read from the tree at execution time. All code steps show concrete code.

**Type/name consistency:** `resolveSwiftUIBuild` → `{enabled, runSwiftc, reason, nimArgs}` used identically in Tasks 2 + 5. `darwin_native_surface_create(int32_t)→NSView*`, `darwin_native_surface_backing(int32_t)→const char*`, `zapp_native_surface_emit(int32_t,const char*)`, `zapp_swift_native_surface_create(int32_t,cb)→void*` consistent across Tasks 3–6. `nativeSurface` (WindowOptions) / `wopts_native_surface` / `nativeSurfaceBacking()` consistent across Task 6. ✓
