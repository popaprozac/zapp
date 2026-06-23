import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// ─────────────────────────────────────────────────────────────────────────────
// SwiftUI pane-control spike (2c risk gate) + #665 divider-drag collapse gating.
//
// Original 2c probe (sections 1-3) tested setWidth / setResizable / presentation
// by driving the column BOUNDS (min/ideal/max). See FINDINGS.md.
//
// Section (4) is the #665 experiment: can `collapsible:false` stop the SIDEBAR
// divider-drag collapse? Two mechanisms have already FAILED (see FINDINGS):
//   - the columnVisibility binding clamp → GLITCH (collapse → snap back), in BOTH
//     the NSHostingController hybrid AND a real SwiftUI Scene. Host is not the var.
//   - SwiftUI's `.navigationSplitViewColumnWidth(min==max)` → does NOT gate the drag.
//
// This run tests the AppKit-level lever the research points to: reach
// NavigationSplitView's REAL backing NSSplitView (here via a dependency-free
// manual finder — the same thing swiftui-introspect would do, but version-token
// proof) and lock the sidebar SPLIT ITEM with the full combination:
//     canCollapse = false
//     canCollapseFromWindowResize = false
//     minimumThickness = minW        ← hard floor: divider can't reach collapse
// No clamp this run, so whatever we SEE is the AppKit lock alone.
// ─────────────────────────────────────────────────────────────────────────────

enum SplitStyleChoice: String, CaseIterable, Identifiable {
  case automatic, balanced, prominentDetail
  var id: String { rawValue }
}

final class Model: ObservableObject {
  // The sidebar column bounds we mutate at runtime (the setWidth/setResizable proxy).
  @Published var minW: CGFloat = 180
  @Published var idealW: CGFloat = 260
  @Published var maxW: CGFloat = 480
  @Published var style: SplitStyleChoice = .balanced
  @Published var columnVisibility: NavigationSplitViewVisibility = .all

  // (4) #665: when false → apply the AppKit collapse-lock to the backing NSSplitView.
  @Published var collapsibleAllowed: Bool = true
  // The locker writes here so the UI can SHOW whether introspection found the split
  // view + applied the lock (guards against false negatives from "never found it").
  @Published var lockStatus: String = "—"

  // (1) setWidth(px): pin min == ideal == max == px.
  func setWidth(_ px: CGFloat) { minW = px; idealW = px; maxW = px }
  // setResizable(true): restore a real drag range.
  func unlock(min: CGFloat = 180, ideal: CGFloat = 260, max: CGFloat = 480) {
    minW = min; idealW = ideal; maxW = max
  }
  // (2) setResizable(false): lock at the current ideal (pin min == max == ideal).
  func lockAtCurrent() { minW = idealW; maxW = idealW }

  var status: String {
    "min \(Int(minW)) · ideal \(Int(idealW)) · max \(Int(maxW)) · style \(style.rawValue) · " +
    (columnVisibility == .all ? "shown" : "collapsed") + " · " +
    "collapsible \(collapsibleAllowed ? "ON" : "OFF") · lock: \(lockStatus)"
  }
}

struct ControlPanel: View {
  @ObservedObject var model: Model

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("2c pane-control probe").font(.title2).bold()
        Text(model.status).font(.system(.callout, design: .monospaced))
          .padding(8).background(.quaternary).cornerRadius(6)

        group("(1) setWidth — pin to an exact width (min==ideal==max)") {
          HStack {
            ForEach([200, 280, 360, 440], id: \.self) { w in
              Button("→ \(w)") { withAnimation { model.setWidth(CGFloat(w)) } }
            }
          }
        }

        group("(2) setResizable — lock / unlock the drag handle") {
          HStack {
            Button("Lock @ current") { withAnimation { model.lockAtCurrent() } }
            Button("Unlock (180–480)") { withAnimation { model.unlock() } }
          }
          Text("After 'Unlock', try dragging the sidebar divider — it should resize. " +
               "After 'Lock', the divider should refuse to move.")
            .font(.caption).foregroundStyle(.secondary)
        }

        group("(3) presentation — tile vs overlay (style + visibility)") {
          Picker("Style", selection: $model.style) {
            ForEach(SplitStyleChoice.allCases) { Text($0.rawValue).tag($0) }
          }.pickerStyle(.segmented)
          HStack {
            Button("Collapse") { withAnimation { model.columnVisibility = .detailOnly } }
            Button("Show") { withAnimation { model.columnVisibility = .all } }
          }
        }

        group("(4) collapsible OFF — #665 AppKit-LOCK test") {
          Toggle("collapsible allowed (OFF = lock the backing NSSplitView)", isOn: $model.collapsibleAllowed)
          Text("THE EXPERIMENT: turn collapsible OFF, then DRAG the sidebar divider " +
               "all the way LEFT (past min). This run reaches NavigationSplitView's " +
               "REAL NSSplitView and sets canCollapse=false + canCollapseFromWindowResize=" +
               "false + minimumThickness=minW (a hard floor) on the sidebar item. " +
               "Report: (a) divider bottoms out at min and WON'T collapse — WIN; " +
               "(b) still collapses/glitches — AppKit lock also defeated. " +
               "Watch the 'lock:' field in the status line — it must read 'applied' " +
               "(if it says 'no split view' the introspection missed and the test is void).")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  @ViewBuilder private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.headline)
      content()
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background.secondary)
    .cornerRadius(8)
  }
}

#if os(macOS)
// Manual "introspection" — the same thing swiftui-introspect does, but dependency-
// and version-token-free (so macOS 26 can't silently no-op it). Mounted in the
// sidebar subtree; finds the enclosing NavigationSplitView NSSplitView and applies
// the AppKit collapse locks that SwiftUI's column-width modifier does NOT honor.
struct SplitViewLocker: NSViewRepresentable {
  @ObservedObject var model: Model

  func makeNSView(context: Context) -> NSView { NSView() }

  func updateNSView(_ nsView: NSView, context: Context) {
    let allowed = model.collapsibleAllowed
    let minW = model.minW
    // Re-apply a few times to catch NavigationSplitView re-deriving the item after
    // layout (the failure mode of one-shot canCollapse).
    for delay in [0.0, 0.1, 0.3] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        applyLock(from: nsView, allowed: allowed, minW: minW)
      }
    }
  }

  private func applyLock(from view: NSView, allowed: Bool, minW: CGFloat) {
    guard let split = findSplitView(from: view) else {
      if model.lockStatus != "no split view" { model.lockStatus = "no split view" }
      return
    }
    guard let controller = split.delegate as? NSSplitViewController,
          let sidebarItem = controller.splitViewItems.first else {
      if model.lockStatus != "no controller" { model.lockStatus = "no controller" }
      return
    }
    sidebarItem.canCollapse = allowed
    if #available(macOS 14.0, *) {
      sidebarItem.canCollapseFromWindowResize = allowed
    }
    sidebarItem.minimumThickness = allowed ? NSSplitViewItem.unspecifiedDimension : minW
    let s = allowed ? "applied(open)" : "applied(locked)"
    if model.lockStatus != s { model.lockStatus = s }
  }

  private func findSplitView(from view: NSView) -> NSSplitView? {
    var v: NSView? = view
    while let cur = v {
      if let sp = cur as? NSSplitView { return sp }
      v = cur.superview
    }
    if let root = view.window?.contentView { return descend(root) }
    return nil
  }
  private func descend(_ view: NSView) -> NSSplitView? {
    if let sp = view as? NSSplitView { return sp }
    for sub in view.subviews {
      if let found = descend(sub) { return found }
    }
    return nil
  }
}
#endif

// Applying a runtime-chosen NavigationSplitViewStyle requires a typed switch
// (the protocol is not directly switchable). A small modifier does it.
extension View {
  @ViewBuilder func splitStyle(_ c: SplitStyleChoice) -> some View {
    switch c {
    case .automatic:       self.navigationSplitViewStyle(.automatic)
    case .balanced:        self.navigationSplitViewStyle(.balanced)
    case .prominentDetail: self.navigationSplitViewStyle(.prominentDetail)
    }
  }
}

#if os(macOS)
final class MacAppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }
}
#endif

struct SpikeApp: App {
  #if os(macOS)
  @NSApplicationDelegateAdaptor(MacAppDelegate.self) var appDelegate
  #endif
  @StateObject private var model = Model()
  var body: some Scene {
    WindowGroup {
      NavigationSplitView(columnVisibility: $model.columnVisibility) {
        ZStack {
          Color.teal.opacity(0.25).ignoresSafeArea()
          VStack(spacing: 12) {
            Text("SIDEBAR").font(.headline)
            Text("width follows\nmin/ideal/max").multilineTextAlignment(.center)
              .font(.caption).foregroundStyle(.secondary)
          }.padding()
        }
        .navigationSplitViewColumnWidth(min: model.minW, ideal: model.idealW, max: model.maxW)
        #if os(macOS)
        .background(SplitViewLocker(model: model))   // (4) #665 AppKit collapse-lock
        #endif
      } detail: {
        ControlPanel(model: model).navigationTitle("2c probe")
      }
      .splitStyle(model.style)
      // Messages-style forced TILE: a window minimum that accommodates the sidebar's
      // min + a content min (window-narrow forced-tile — distinct from divider-drag).
      .frame(minWidth: model.minW + 360, minHeight: 360)
    }
  }
}

SpikeApp.main()
