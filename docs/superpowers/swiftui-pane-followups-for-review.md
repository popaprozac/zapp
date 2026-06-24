> **HISTORICAL (2026-06-23):** superseded by the SwiftUI-pane removal — see docs/superpowers/specs/2026-06-23-remove-swiftui-pane-path-design.md. Kept for archaeology.

# Zapp SwiftUI pane path — two open problems (for external review)

Context for a fresh reviewer (e.g. Gemini). Zapp is a native-first app framework. On
macOS it can host its sidebar/inspector panes two ways:

- **AppKit path** (`native: { swiftui: false }`): a real `NSSplitViewController` /
  `NSSplitViewItem`. Rock-solid; nothing re-derives geometry behind our back.
- **SwiftUI pane path** (default, macOS 14+): a SwiftUI `NavigationSplitView` + `.inspector`
  hosted in an **`NSHostingController` set as `window.contentViewController`** of an
  otherwise imperative `NSWindow`. We took this for SwiftUI's `.toolbar` titlebar
  integration. It is NOT a SwiftUI `App`/`WindowGroup` (Zapp creates windows imperatively
  from C/Nim, including from background workers — a real `WindowGroup` was spiked and is
  architecturally incompatible, see "Already ruled out").

Each pane is a **`WKWebView`** wrapped in a tiny `NSViewRepresentable` (`PaneHost`) that
returns a pre-built `NSView` container WITHOUT re-parenting the webview.

Both problems below are specific to the SwiftUI pane path.

---

## Hard constraints / things already ruled out (please don't re-propose)

1. **Cannot become a SwiftUI `@main App`/`WindowGroup`.** Zapp owns `NSApplication`,
   creates `NSWindow`s imperatively (`darwin_window_create`) tracked in a numeric-ID
   registry, and spawns windows from worker threads at runtime. A real `WindowGroup`
   requires SwiftUI to own window creation — incompatible. (Spiked → NO-GO.)
2. **`.navigationSplitViewColumnWidth(min:ideal:max:)` is initial-only at runtime.**
   SwiftUI ignores changes to its min/ideal/max on an already-laid-out column. Runtime
   width must be imperative (`NSSplitView setPosition`).
3. **The `columnVisibility` binding-clamp glitches.** Refusing `.detailOnly` in the
   binding setter catches a collapse only AFTER it visually happens (flash → snap back),
   even in a pure SwiftUI `WindowGroup` test app.
4. **`NSSplitViewItem.canCollapse = false` alone doesn't stop a divider drag** on
   `NavigationSplitView` (macOS 26). What DOES work: `canCollapse=false` +
   `canCollapseFromWindowResize=false` + a hard `minimumThickness` floor (the divider
   physically can't cross it). We reach the real `NSSplitView` via a dependency-free
   view-tree walk (no `swiftui-introspect`).
5. **Replacing the split's delegate crashes** (`-[NSSplitView setDelegate:]` asserts the
   `NSSplitViewController` owns it → SIGABRT).
6. **A Swift-side `forceInitialWidth` (set the column to the configured width until a
   rendered-width match) was tried and reverted** — it latched too early on a transient
   match, and its create-time `setPosition` destabilized the window chrome layout.

We already have a durable geometry owner that works well for resize-lock / min / max /
maxWidth-clip — re-asserted on `NSSplitView.didResizeSubviewsNotification`:

```swift
// SwiftUI view mounted in the sidebar subtree; finds the backing NSSplitView and
// owns the sidebar NSSplitViewItem geometry. Re-asserts on every *resize* relayout.
struct PaneGeometryLocker: NSViewRepresentable {
  @ObservedObject var state: PaneState
  let role: ZappPaneRole // .sidebar | .inspector

  final class Coordinator { /* width,minW,maxW,resizable,collapsible; weak observed; token */ }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView { NSView() }

  func updateNSView(_ nsView: NSView, context: Context) {
    // copy PaneState fields into coordinator, then apply on 0/0.1/0.3s ticks
  }

  private func enforce(_ pane: NSSplitViewItem, _ c: Coordinator) {
    let maxT = c.resizable ? c.maxW : c.width
    let minT = c.resizable ? c.minW : c.width
    if pane.canCollapse != c.collapsible { pane.canCollapse = c.collapsible }
    if pane.canCollapseFromWindowResize != c.collapsible { pane.canCollapseFromWindowResize = c.collapsible }
    if pane.maximumThickness != maxT { pane.maximumThickness = maxT }
    if pane.minimumThickness != minT { pane.minimumThickness = minT }
  }

  private func apply(from view: NSView, _ c: Coordinator) {
    guard let split = findSplitView(from: view),
          let controller = split.delegate as? NSSplitViewController,
          let pane = (role == .sidebar ? controller.splitViewItems.first
                                       : controller.splitViewItems.last) else { return }
    enforce(pane, c)
    if c.observed !== split {           // attach ONCE
      c.observed = split
      c.token = NotificationCenter.default.addObserver(
        forName: NSSplitView.didResizeSubviewsNotification, object: split, queue: .main) { _ in
          if let pane = (role == .sidebar ? controller.splitViewItems.first
                                          : controller.splitViewItems.last) { enforce(pane, c) }
        }
    }
  }
}
```

---

## Problem A — create-time settle is visible (CSS chrome vars + initial sidebar width)

On launch there's a brief visible "settle": the content/chrome jumps once after the
SwiftUI toolbar + split finish their async layout. Two values land late, and right now we
chase them with **guessed `dispatch_after` delays**, which is both noticeable and not
clean. We want the **lowest possible delay / an event-driven trigger**.

### A1 — chrome CSS variables (`--zapp-titlebar-height`, `--zapp-toolbar-height`)

The webview is told the top-chrome inset via CSS vars so web content lays out below the
titlebar+toolbar. They're computed from `frame − contentLayoutRect`:

```objc
// toolbar.m — measures the chrome band and injects the CSS vars into the pane webviews.
void zapp_toolbar_inject_metrics(void* window_ptr, int32_t host_slot, bool add_user_script) {
    NSWindow* window = (__bridge NSWindow*)window_ptr;
    CGFloat totalInset = window.frame.size.height - window.contentLayoutRect.size.height; // titlebar+toolbar band
    // ...measure NSToolbarView row height for --zapp-toolbar-height (0 on the SwiftUI path)...
    NSString* js = [NSString stringWithFormat:
        @"document.documentElement.style.setProperty('--zapp-titlebar-height','%.0fpx');"
        @"document.documentElement.style.setProperty('--zapp-toolbar-height','%.0fpx');",
        totalInset, toolbarH];
    // inject into host + sidebar + inspector webviews (optionally as a persisted WKUserScript)
}
```

The problem: at **webview-create time** the SwiftUI `.toolbar` hasn't rendered yet, so
`contentLayoutRect` is too tall → `titlebar-height` too small → content underlaps the
toolbar. The AppKit path fixes this with a **`contentLayoutRect` KVO** that re-injects the
moment the band changes:

```objc
// toolbar.m — AppKit path: deterministic re-inject via KVO (this is the clean pattern).
[window addObserver:controller forKeyPath:@"contentLayoutRect" options:0 context:NULL];
- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(...)c context:(...) {
    if ([keyPath isEqualToString:@"contentLayoutRect"])
        zapp_toolbar_inject_metrics((__bridge void*)self.window, self.hostSlot, false);
}
```

But the SwiftUI path **skips the NSToolbar attach** (SwiftUI owns the toolbar), so it
currently gets NO KVO — we bolted on guessed delays instead:

```objc
// window.m — SwiftUI path today: GUESSED re-inject (what we want to replace).
else if (swiftUIToolbar) {
    const double metricDelays[3] = {0.1, 0.4, 0.9};
    for (int mi = 0; mi < 3; mi++)
        dispatch_after(/* metricDelays[mi] s */, dispatch_get_main_queue(), ^{
            zapp_toolbar_inject_metrics((__bridge void*)swWindow, hsMetrics, mi == 2);
        });
}
```

**Ask A1:** the cleanest deterministic trigger? Our lead is registering the SAME
`contentLayoutRect` KVO for SwiftUI-pane windows (fires exactly when the toolbar lays
out). Any caveat with KVO-ing `contentLayoutRect` on an `NSHostingController`-backed
window? Other signals (e.g. `NSWindow.didUpdateNotification`, the hosting controller's
`viewDidLayout`, `NSViewController.viewDidAppear`)?

### A2 — initial sidebar width

The configured sidebar width (e.g. 240) doesn't take at launch: `NavigationSplitView`
estimates the column narrow while the webview mounts and ignores the modifier's `ideal`
at runtime (constraint #2). We snap it imperatively, post-mount, with guessed delays:

```objc
// window.m — SwiftUI path: GUESSED width snap (what we want to replace).
const double snapDelays[3] = {0.1, 0.4, 0.9};
for (int si = 0; si < 3; si++)
    dispatch_after(/* snapDelays[si] s */, dispatch_get_main_queue(), ^{
        darwin_sidebar_set_width(hsForWidth, cfgSidebarW); // resolves split → NSSplitView setPosition
    });
```

**Ask A2:** the deterministic moment the split has done its REAL (non-estimate) layout, so
we snap once with no visible shift? Candidates we're weighing:
(a) pre-size the sidebar container `NSView` to the configured width *before* building the
hosting controller, so `NavigationSplitView` never estimates narrow (does the column honor
the wrapped `NSView`'s width over its own estimate?);
(b) snap from the existing `PaneGeometryLocker` `didResizeSubviews` observer, but only once
the rendered width is stable / the webview has loaded (how to detect "settled" without
fighting a user drag?);
(c) snap on the sidebar `WKWebView`'s `didFinishNavigation`;
(d) something cleaner.

---

## Problem B (#673) — collapse-gating decays after a content-only relayout (route change)

`collapsible: false` is meant to prevent the user collapsing the sidebar (divider drag +
toggle). We enforce it by locking the backing `NSSplitViewItem`:
`canCollapse=false` + `canCollapseFromWindowResize=false` + a hard `minimumThickness`
floor (see `enforce()` above). This works AND survives window resize (the
`didResizeSubviews` observer re-asserts it).

**The bug:** after a **content-only relayout** — e.g. the app swaps the *detail* pane's
DOM on an in-app route change, with NO change to the split's subview sizes —
`NavigationSplitView` **re-derives the sidebar item's `canCollapse` back to `true`**, and
our `NSSplitViewDidResizeSubviews` observer **does not fire** (nothing resized). So
`collapsible:false` silently lapses: the user can drag-collapse again, even though the
app-rendered toggle stays greyed.

Confirming details:
- Re-running the lock fixes it instantly. The app-facing `setCollapsible(false)` flips a
  `@Published` field → SwiftUI re-renders → `updateNSView` runs `enforce()` again → gated
  again. So the enforce logic is correct; the only gap is a **trigger** for content-only
  relayouts.
- A window *resize* re-gates it (the observer fires). A *route change* does not.

```swift
// What we have: re-assert fires on @Published changes (updateNSView) + on resize
// (didResizeSubviews). Neither fires on a content-only relayout that re-derives canCollapse.
NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification,
                                       object: split, queue: .main) { _ in enforce(pane, c) }
```

**Ask B:** what's a clean hook that fires on EVERY `NavigationSplitView` relayout
(including content-only), from an `NSViewRepresentable` reaching the backing
`NSSplitView`, so we can re-assert `canCollapse` synchronously? Candidates:
(a) KVO on something on the `NSSplitView` / its `NSSplitViewItem` that tracks relayout
(`frame`? `arrangedSubviews`? the item's `canCollapse` itself — observe + correct?);
(b) subclass-free swizzle of `-[NSSplitView layout]` / `viewDidLayout` (last resort);
(c) a `CVDisplayLink`/timer re-assert while `collapsible:false` (we dislike: a race window
remains after each relayout, and it's not clean);
(d) accept it as a documented SwiftUI-path limitation (the AppKit path,
`native:{swiftui:false}`, has none of this — real `NSSplitViewController`, no
re-derivation).

We lean toward (d) unless there's a clean (a). Is there a KVO-able signal that fires when
`NavigationSplitView` re-derives its item state?

---

## TL;DR for the reviewer

- We host SwiftUI `NavigationSplitView` in an `NSHostingController` (can't be a real
  `WindowGroup`). We reach the backing `NSSplitView`/`NSSplitViewItem` and enforce geometry
  imperatively because the declarative modifiers are initial-only / soft.
- **A:** we re-inject chrome CSS vars + snap the initial sidebar width with guessed
  `dispatch_after` delays → visible settle. Want a deterministic event trigger (KVO on
  `contentLayoutRect`? a layout callback?).
- **B (#673):** `canCollapse=false` decays after content-only relayouts (route changes)
  that re-derive the item but don't fire `didResizeSubviews`. Want a hook that catches
  every relayout — or confirmation that (d) accept-the-limit is the right call.
