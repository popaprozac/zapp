# SwiftUI + WKWebView + `.inspector` adaptivity spike — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove (GO/NO-GO) that a `WKWebView` hosted inside a SwiftUI representable keeps its JS↔native script-message bridge, and that SwiftUI `.inspector` adapts (column on macOS/iPad, bottom sheet on iPhone), via a throwaway pure-Swift harness.

**Architecture:** A standalone `swiftc`-built SwiftUI `@main` app in `spikes/swiftui-webview-inspector/` — `NavigationSplitView` with a `WKWebView` (via a conditional-compiled `NSViewRepresentable`/`UIViewRepresentable`) as the detail's primary content, plus a `.inspector` accessory and a `WKScriptMessageHandler` round-trip. No Nim, no Zapp build, wired to nothing.

**Tech Stack:** Swift 6.3 (`swiftc`), SwiftUI, WebKit, `xcrun simctl`. macOS 14 / iOS 17 floors (`.inspector` requirement). macOS host.

**Branch:** `feat/nim-native` (do not merge to main). **Commit trailer (every commit):**
```
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

**Spec:** `docs/superpowers/specs/2026-06-20-swiftui-webview-inspector-spike-design.md`
**Reference (swiftc/simctl pattern):** `spikes/swiftui-nim/build.sh` + `spikes/swiftui-nim/FINDINGS.md`

---

## Verification model (read first)

This is a **spike**: there are **no unit tests**. Verification is **build-succeeds + run + human visual confirm**, exactly like `spikes/swiftui-nim/`. Two gates are human visual confirmations and are legitimate pause points:
- **Gate 1 (Task 2, macOS)** — if it fails, that is a **NO-GO**: stop, record the finding, do not proceed to iOS.
- **Gate 2 (Task 4, iOS-sim)** — only after Gate 1 passes.

Non-goals (do NOT build): Nim integration, the real `ZappWebView` bridge, real accessory re-implementation, older-OS fallback.

---

## File Structure

**Create (all under `spikes/swiftui-webview-inspector/`):**
- `Probe.swift` — the entire harness: inline HTML, `WebCoordinator` (`WKScriptMessageHandler`), the cross-platform `WebView` representable, `InspectorContent`, `RootView` (`NavigationSplitView` + `.inspector`), and the `@main` app.
- `build.sh` — `macos` and `ios-sim` stages (`swiftc` + the iOS `.app` assembly).
- `FINDINGS.md` — the GO/NO-GO scorecard (written in Task 5).

---

## Task 1: Harness (`Probe.swift`) + macOS build

**Files:**
- Create: `spikes/swiftui-webview-inspector/Probe.swift`
- Create: `spikes/swiftui-webview-inspector/build.sh`

- [ ] **Step 1: Write `Probe.swift`**

```swift
import SwiftUI
import WebKit

// Trivial page: a button posts to the native handler; a status line shows the
// native round-trip. This is the *visible* proof the bridge survives the
// SwiftUI representable.
let probeHTML = """
<!doctype html><html><head>
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<style>
  body { font: -apple-system, system-ui, sans-serif; margin: 0; padding: 24px; background: #f2f2f7; color: #111; }
  button { font-size: 18px; padding: 12px 20px; border-radius: 10px; border: 0; background: #0a84ff; color: #fff; }
  #status { margin-top: 16px; font-size: 16px; color: #555; }
</style></head>
<body>
  <h2>WKWebView — primary content</h2>
  <button onclick="window.webkit.messageHandlers.probe.postMessage('ping')">postMessage("ping")</button>
  <div id="status">status: (no round-trip yet)</div>
  <script>
    function nativeSays(s){ document.getElementById('status').textContent = 'status: ' + s; }
  </script>
</body></html>
"""

// Receives JS messages and echoes back via evaluateJavaScript — the bridge proof.
final class WebCoordinator: NSObject, WKScriptMessageHandler {
  weak var webView: WKWebView?
  var onPing: (() -> Void)?
  func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.name == "probe" else { return }
    onPing?()
    webView?.evaluateJavaScript("nativeSays('pong from native ✓')", completionHandler: nil)
  }
}

// One representable that builds for both platforms.
#if os(macOS)
typealias PlatformViewRepresentable = NSViewRepresentable
#else
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

struct WebView: PlatformViewRepresentable {
  var onPing: () -> Void

  func makeCoordinator() -> WebCoordinator {
    let c = WebCoordinator()
    c.onPing = onPing
    return c
  }

  private func buildWebView(_ coordinator: WebCoordinator) -> WKWebView {
    let cfg = WKWebViewConfiguration()
    let ucc = WKUserContentController()
    ucc.add(coordinator, name: "probe")
    cfg.userContentController = ucc
    let wv = WKWebView(frame: .zero, configuration: cfg)
    coordinator.webView = wv
    wv.loadHTMLString(probeHTML, baseURL: nil)
    return wv
  }

  #if os(macOS)
  func makeNSView(context: Context) -> WKWebView { buildWebView(context.coordinator) }
  func updateNSView(_ nsView: WKWebView, context: Context) {}
  #else
  func makeUIView(context: Context) -> WKWebView { buildWebView(context.coordinator) }
  func updateUIView(_ uiView: WKWebView, context: Context) {}
  #endif
}

struct InspectorContent: View {
  let pings: Int
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Inspector").font(.headline)
      Text("A SwiftUI .inspector accessory.").foregroundStyle(.secondary)
      Text("bridge round-trips: \(pings)")
      Spacer()
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

struct RootView: View {
  @State private var showInspector = true
  @State private var pings = 0
  @State private var selection: String? = "Home"
  private let items = ["Home", "Two", "Three"]

  var body: some View {
    NavigationSplitView {
      List(items, id: \\.self, selection: $selection) { Text($0) }
        .navigationTitle("Sidebar")
    } detail: {
      WebView(onPing: { pings += 1 })
        .ignoresSafeArea()
        .inspector(isPresented: $showInspector) {
          InspectorContent(pings: pings)
            .inspectorColumnWidth(min: 200, ideal: 280, max: 420)
        }
        .toolbar {
          Button {
            showInspector.toggle()
          } label: {
            Label("Toggle Inspector", systemImage: "sidebar.trailing")
          }
        }
    }
  }
}

@main
struct ProbeApp: App {
  var body: some Scene {
    WindowGroup { RootView() }
  }
}
```

(Note the doubled backslash in `id: \\.self` is for this plan's markdown; write a single backslash `id: \.self` in the actual file.)

- [ ] **Step 2: Write `build.sh`**

```bash
#!/usr/bin/env bash
# SwiftUI + WKWebView + .inspector spike. Usage: ./build.sh [macos|ios-sim]
set -euo pipefail
cd "$(dirname "$0")"
STAGE="${1:-macos}"
mkdir -p build
BUNDLE_ID="dev.zapp.spike.swiftuiwebview"

case "$STAGE" in
  macos)
    swiftc -O -target arm64-apple-macos14.0 Probe.swift -o build/probe
    echo "--- built build/probe ($(du -h build/probe | cut -f1)) ---"
    echo "run it:  ./build/probe   (click the window if it opens behind)"
    ;;
  ios-sim)
    SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
    swiftc -O -sdk "$SDK" -target arm64-apple-ios17.0-simulator Probe.swift -o build/Probe
    APP="build/Probe.app"
    rm -rf "$APP"; mkdir -p "$APP"
    cp build/Probe "$APP/Probe"
    cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Probe</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>Probe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>UILaunchScreen</key><dict/>
  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
  <key>MinimumOSVersion</key><string>17.0</string>
</dict></plist>
PLIST
    echo "--- built $APP ---"
    echo "boot a sim (iPhone for the SHEET, iPad for the COLUMN), then:"
    echo "  xcrun simctl install booted $APP && xcrun simctl launch booted ${BUNDLE_ID}"
    ;;
  *) echo "stage '$STAGE' unknown (macos|ios-sim)"; exit 2 ;;
esac
```

- [ ] **Step 3: Make executable + build for macOS**

Run:
```bash
chmod +x spikes/swiftui-webview-inspector/build.sh
spikes/swiftui-webview-inspector/build.sh macos
```
Expected: ends with `--- built build/probe (…) ---` and **no `swiftc` errors**. If `swiftc` errors, fix `Probe.swift` so it compiles cleanly for `arm64-apple-macos14.0` (keep the API shape: `WebView` representable, `.inspector`, `WKScriptMessageHandler` named `"probe"`).

- [ ] **Step 4: Commit**

```bash
git add spikes/swiftui-webview-inspector/Probe.swift spikes/swiftui-webview-inspector/build.sh
git commit -m "spike(swiftui-webview): harness — WKWebView-in-representable + .inspector (macOS build)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 2: GATE 1 — macOS (build + run + human visual) · NO-GO stop point

**Files:** none (verification only)

- [ ] **Step 1: Build + launch on macOS**

Run:
```bash
spikes/swiftui-webview-inspector/build.sh macos && spikes/swiftui-webview-inspector/build/probe &
```
(If the window opens behind other apps, click it / find it in the Dock — a bare `swiftc` binary may not auto-foreground; the prior spike noted this. The window still renders.)

- [ ] **Step 2: Human visual confirm (PAUSE for the user)**

Ask the user to confirm ALL of:
1. A window shows a **`NavigationSplitView` sidebar** (Home/Two/Three) + a **webview detail** rendering the HTML ("WKWebView — primary content" + button).
2. An **inspector COLUMN** is visible on the trailing edge (the "Inspector" panel).
3. Clicking the HTML **postMessage("ping")** button changes the page status line to **"pong from native ✓"** (the bridge round-trips through the representable) AND the inspector's "bridge round-trips: N" increments.
4. The toolbar **Toggle Inspector** button hides/shows the inspector column.

**If all confirmed → Gate 1 PASS, proceed to Task 3.**
**If the bridge round-trip fails, or `.inspector` is unusable with the webview primary → Gate 1 FAIL = NO-GO:** stop here, skip Tasks 3–4, and go straight to Task 5 to record the NO-GO finding.

- [ ] **Step 3: Kill the app**

Run: `pkill -f "swiftui-webview-inspector/build/probe" || true`

---

## Task 3: iOS-sim build (`build.sh ios-sim`)

**Files:** none new (the `ios-sim` stage was written in Task 1)

- [ ] **Step 1: Build the iOS-sim `.app`**

Run:
```bash
spikes/swiftui-webview-inspector/build.sh ios-sim
```
Expected: ends with `--- built build/Probe.app ---` and the printed install/launch line; **no `swiftc` errors**. If the cross-compile errors (e.g. an API unavailable on iOS 17), adjust `Probe.swift` under `#if os(iOS)` while keeping the shared API shape — but the harness should already be iOS-clean (`.inspector`/`NavigationSplitView` are iOS 17 / 16).

- [ ] **Step 2: Commit (only if Task 1 didn't already capture build.sh as-is)**

The `ios-sim` stage shipped in Task 1's `build.sh`. If Task 3 required edits to `Probe.swift` or `build.sh`, commit them:
```bash
git add spikes/swiftui-webview-inspector/Probe.swift spikes/swiftui-webview-inspector/build.sh
git commit -m "spike(swiftui-webview): iOS-sim build (.app + simctl)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
If no edits were needed, skip the commit (nothing changed).

---

## Task 4: GATE 2 — iOS-sim (iPhone sheet / iPad column) · human visual

**Files:** none (verification only)

- [ ] **Step 1: Run on an iPhone simulator**

Run (boot an iPhone sim first — open Simulator.app and pick an iPhone, or `xcrun simctl boot "iPhone 15"`):
```bash
xcrun simctl install booted spikes/swiftui-webview-inspector/build/Probe.app
xcrun simctl launch booted dev.zapp.spike.swiftuiwebview
```

- [ ] **Step 2: Human visual confirm — iPhone (PAUSE for the user)**

Ask the user to confirm on the **iPhone** sim:
1. The webview content renders.
2. The inspector presents as a **bottom SHEET** (not a column) — this is the size-class adaptivity payoff.
3. The **postMessage("ping")** button still round-trips ("pong from native ✓").

- [ ] **Step 3: Run on an iPad simulator**

Boot an iPad sim (open Simulator.app → an iPad, or `xcrun simctl boot "iPad Pro 11-inch (M4)"` — pick any available iPad), then:
```bash
xcrun simctl install booted spikes/swiftui-webview-inspector/build/Probe.app
xcrun simctl launch booted dev.zapp.spike.swiftuiwebview
```

- [ ] **Step 4: Human visual confirm — iPad (PAUSE for the user)**

Ask the user to confirm on the **iPad** sim:
1. The inspector presents as a trailing **COLUMN** (not a sheet).
2. The bridge round-trip still works.

**Gate 2 PASS if iPhone = sheet, iPad = column, bridge works on both.**

---

## Task 5: FINDINGS.md scorecard + GO/NO-GO verdict

**Files:**
- Create: `spikes/swiftui-webview-inspector/FINDINGS.md`

- [ ] **Step 1: Write `FINDINGS.md`**

Fill in the ACTUAL observed results (not assumptions). Template:

```markdown
# SwiftUI + WKWebView + .inspector adaptivity spike — FINDINGS

**Date:** 2026-06-20 · **Toolchain:** Swift 6.3 (swiftc) · macOS host · floors macOS 14 / iOS 17

## Verdict: <GO | NO-GO>

<1–2 sentences: can a WKWebView in a SwiftUI representable keep its bridge, and does
.inspector adapt? Bottom line for the feature cycle.>

## Scorecard
| Question | Result |
|---|---|
| WKWebView in a SwiftUI representable keeps its WKScriptMessageHandler round-trip | <PASS/FAIL> |
| .inspector renders a COLUMN on macOS | <PASS/FAIL> |
| .inspector renders a COLUMN on iPad | <PASS/FAIL> |
| .inspector becomes a bottom SHEET on iPhone | <PASS/FAIL> |
| Builds on macOS (arm64-apple-macos14) | <PASS/FAIL> |
| Builds + runs on iOS-sim (arm64-apple-ios17-simulator) | <PASS/FAIL> |

## The working incantation (reproduces from clean)
```bash
cd spikes/swiftui-webview-inspector
./build.sh macos   && ./build/probe                      # Gate 1
./build.sh ios-sim                                       # Gate 2: then install/launch on iPhone + iPad sims
xcrun simctl install booted build/Probe.app && xcrun simctl launch booted dev.zapp.spike.swiftuiwebview
```

## Notes / gotchas
<anything surprising: bare-binary macOS activation, representable lifecycle, sheet detents,
toolbar placement on iOS, etc.>

## If GO — what the feature cycle must solve
1. Re-plumb the REAL ZappWebView (custom scheme handler, the "zapp" script handler, drag
   regions, traffic-light insets, KVO chrome metrics, embeddable panels) through the
   representable's Coordinator — confirm none break when SwiftUI-hosted.
2. @available gating (macOS 14 / iOS 17 floors) + graceful fallback to the current AppKit
   NSSplitViewItem / UIKit hand-rolled inspector for older OS or opt-out.
3. Nim-side wiring — select + drive the SwiftUI shell from the Nim window layer, reusing the
   resolver pattern from the native-surface cycle.
4. Coexistence with the rest of Zapp's window chrome (toolbar, tray, window controls).

## Reproduce / cleanup
Harness is standalone + throwaway. Keep as reference, or delete
`spikes/swiftui-webview-inspector/` — the verdict + incantation live here.
```

- [ ] **Step 2: Commit**

```bash
git add spikes/swiftui-webview-inspector/FINDINGS.md
git commit -m "spike(swiftui-webview): FINDINGS scorecard + GO/NO-GO verdict

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 3: Present the verdict to the user**

Summarize the scorecard + verdict + (if GO) the feature-cycle prerequisites. Do not start the feature cycle — that's a separate brainstorm→spec→plan.

---

## Self-Review (against the spec)

**Spec coverage:**
- §"Two unknowns" — bridge survival → Task 1 (`WebCoordinator` + `ucc.add(…, "probe")`) + Task 2 Step 2.3 / Task 4. `.inspector` adaptivity → Task 1 (`.inspector`) + Gate 1 (column) + Gate 2 (sheet/column). ✓
- §"Shape" (throwaway pure-Swift harness, `spikes/swiftui-webview-inspector/`, no Nim/Zapp) → Tasks 1, file structure. ✓
- §"Components" (`Probe.swift` with NavigationSplitView/WebView representable/handler/inline HTML/InspectorContent/SidebarList; `build.sh` macos + ios-sim stages; `FINDINGS.md`) → Tasks 1, 5. ✓
- §"Gates" (macOS column + bridge; iOS-sim iPhone sheet / iPad column; build+run+visual, no unit tests; NO-GO stop) → Tasks 2 (NO-GO gate), 3, 4. ✓
- §"Deliverable" (scorecard, incantation, GO/NO-GO, feature-cycle prereqs) → Task 5. ✓
- §"Non-goals" — not built (no Nim/real-bridge/real-accessory/fallback tasks). ✓

**Placeholder scan:** `FINDINGS.md` has `<…>` fill-ins by design (the engineer records ACTUAL results at Task 5) — that is data-to-observe, not an unfinished plan step. All code steps (`Probe.swift`, `build.sh`) are complete and copy-pasteable. The `id: \.self` backslash caveat is called out explicitly.

**Consistency:** `"probe"` script-message name is identical in the HTML (`messageHandlers.probe`), the handler (`message.name == "probe"`), and `ucc.add(…, name: "probe")`. Bundle id `dev.zapp.spike.swiftuiwebview` is identical in `build.sh` Info.plist and the Task 4 launch commands. Targets `arm64-apple-macos14.0` / `arm64-apple-ios17.0-simulator` consistent across `build.sh` + tasks. App type is a SwiftUI `@main` app named `ProbeApp` with `RootView`. ✓
