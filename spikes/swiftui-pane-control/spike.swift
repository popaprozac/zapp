import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// ─────────────────────────────────────────────────────────────────────────────
// SwiftUI pane-control spike (2c risk gate).
//
// Three unknowns for Sub-cycle 2c (runtime sidebar control on the SwiftUI
// NavigationSplitView path, macOS). SwiftUI exposes column *bounds*
// (min/ideal/max), not an imperative "set this column to N px now" — so we test
// whether external @State driving those bounds can stand in for:
//
//   (1) setWidth(px)     — pin the sidebar to an exact width by setting
//                          min == ideal == max == px. Does the column actually
//                          jump there, cleanly, and survive re-layout?
//   (2) setResizable(b)  — lock by pinning min == max == current width; unlock
//                          by restoring a real range. Does the drag handle
//                          actually disable / re-enable?
//   (3) presentation     — force TILE (sidebar beside content) vs OVERLAY
//                          (sidebar floats over content) on macOS. Toggle the
//                          NavigationSplitViewStyle + columnVisibility and SEE
//                          which combination (if any) yields each mode.
//
// Everything is driven from the detail-pane control panel (the proxy for Zapp's
// router pushing sidebar:setWidth / setResizable / presentation at runtime).
// Watch the sidebar column as you tap. The status line echoes the live bounds.
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
    (columnVisibility == .all ? "shown" : "collapsed")
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
          Text("Resize the WINDOW narrow/wide while toggling styles — note when the " +
               "sidebar TILES (pushes content) vs OVERLAYS (floats over content).")
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
      } detail: {
        ControlPanel(model: model).navigationTitle("2c probe")
      }
      .splitStyle(model.style)
    }
  }
}

SpikeApp.main()
