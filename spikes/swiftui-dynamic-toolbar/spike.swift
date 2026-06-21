import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// ─────────────────────────────────────────────────────────────────────────────
// SwiftUI dynamic-toolbar spike (2b Strategy-B de-risk).
//
// Question: can a SwiftUI `.toolbar` whose items are driven by EXTERNAL state
// (a @Published array — the proxy for Zapp's router pushing setItems/updateItem/
// remove) survive BOTH:
//   (1) NavigationSplitView re-layout on navigation  (the "collapse" scenario), and
//   (2) dynamic mutation of the item set            (the Strategy-B-killer: items
//        dropped on update / zero-size warnings)
// …without dropping items?
//
// Constraint learned at build time: you CANNOT `ForEach { ToolbarItem }` — ForEach's
// content is a @ViewBuilder, so it must produce Views, not ToolbarContent. So the
// only two dynamic shapes are a ForEach of *Views* inside:
//   • ToolbarItemGroup   (the previous "dropped items on update" attempt), or
//   • a single ToolbarItem holding an HStack  (the previous "zero-size" attempt).
// Both are tested here, with STABLE Identifiable ids + explicit HStack sizing —
// the two suspected fixes. Toggle between them at runtime to compare.
// ─────────────────────────────────────────────────────────────────────────────

struct ToolbarItemModel: Identifiable, Equatable {
  let id: String          // STABLE identity — the hypothesised fix for "dropped on update"
  var label: String
  var systemImage: String
  var enabled: Bool = true
}

final class Model: ObservableObject {
  @Published var items: [ToolbarItemModel]
  @Published var useHStack: Bool = false   // false = ToolbarItemGroup, true = HStack-in-one-ToolbarItem
  @Published var lastClick: String = "(none)"

  init() { items = Model.setA }

  static let setA: [ToolbarItemModel] = [
    .init(id: "compose", label: "Compose", systemImage: "square.and.pencil"),
    .init(id: "filter",  label: "Filter",  systemImage: "line.3.horizontal.decrease"),
  ]
  static let setB: [ToolbarItemModel] = [
    .init(id: "compose", label: "Compose", systemImage: "square.and.pencil"),
    .init(id: "filter",  label: "Filter",  systemImage: "line.3.horizontal.decrease"),
    .init(id: "share",   label: "Share",   systemImage: "square.and.arrow.up"),
    .init(id: "trash",   label: "Trash",   systemImage: "trash"),
  ]

  func setItems(_ next: [ToolbarItemModel]) { items = next }                       // proxy: router setItems
  func removeAll() { items = [] }                                                  // proxy: toolbar.remove()
  func renameCompose() {                                                           // proxy: updateItem(label/icon)
    guard let i = items.firstIndex(where: { $0.id == "compose" }) else { return }
    let composed = items[i].label != "Composed!"
    items[i].label = composed ? "Composed!" : "Compose"
    items[i].systemImage = composed ? "checkmark.circle" : "square.and.pencil"
  }
  func toggleFilterEnabled() {                                                     // proxy: updateItem(enabled)
    guard let i = items.firstIndex(where: { $0.id == "filter" }) else { return }
    items[i].enabled.toggle()
  }
}

// ── The two candidate toolbar shapes ────────────────────────────────────────
struct DynamicToolbar: ToolbarContent {
  @ObservedObject var model: Model

  var body: some ToolbarContent {
    // if/else in @ToolbarContentBuilder — both arms are valid ToolbarContent.
    if model.useHStack {
      ToolbarItem(placement: .primaryAction) {
        HStack(spacing: 2) {
          ForEach(model.items) { item in iconButton(item) }
        }
        .fixedSize()   // explicit sizing — the suspected fix for the zero-size warning
      }
    } else {
      ToolbarItemGroup(placement: .primaryAction) {
        ForEach(model.items) { item in iconButton(item) }
      }
    }
  }

  @ViewBuilder private func iconButton(_ item: ToolbarItemModel) -> some View {
    Button {
      model.lastClick = item.id
    } label: {
      Label(item.label, systemImage: item.systemImage)
    }
    .disabled(!item.enabled)
    .help(item.label)
  }
}

struct ControlPanel: View {
  @ObservedObject var model: Model
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        Text("Dynamic toolbar spike").font(.title2).bold()
        Text("Watch the TITLEBAR toolbar as you mutate the set. It must always match the list below — no dropped items, no leftovers, no flicker.")
          .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

        Toggle("Use HStack-in-one-ToolbarItem (off = ToolbarItemGroup)", isOn: $model.useHStack)

        Divider()
        Text("Mutations (proxy for native setItems / updateItem / remove):").font(.headline)
        HStack {
          Button("Set A (2)") { model.setItems(Model.setA) }
          Button("Set B (4)") { model.setItems(Model.setB) }
          Button("Rename Compose") { model.renameCompose() }
          Button("Toggle Filter enabled") { model.toggleFilterEnabled() }
        }
        HStack {
          Button("Remove all") { model.removeAll() }
          Button("Re-add A") { model.setItems(Model.setA) }
        }

        Divider()
        Text("Current items (\(model.items.count)) — toolbar must match exactly:").font(.headline)
        ForEach(model.items) { item in
          Text("• \(item.id) — “\(item.label)” [\(item.systemImage)]\(item.enabled ? "" : "  (disabled)")")
            .font(.system(.body, design: .monospaced))
        }
        if model.items.isEmpty { Text("(none)").foregroundStyle(.secondary) }

        Divider()
        Text("Last toolbar click: \(model.lastClick)").foregroundStyle(.secondary)
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

struct RootView: View {
  @StateObject private var model = Model()
  @State private var selection: String? = "Home"
  private let navItems = ["Home", "Two", "Three", "Four"]

  var body: some View {
    NavigationSplitView {
      List(navItems, id: \.self, selection: $selection) { Text($0) }
        .navigationTitle("Nav")
    } detail: {
      ControlPanel(model: model)
        .navigationTitle(selection ?? "—")
        .toolbar { DynamicToolbar(model: model) }
    }
    // Suppress SwiftUI's auto sidebar toggle — confirm it stays suppressed across
    // navigation + mutation (Strategy-A could not make this stick on the NSToolbar
    // path; here SwiftUI owns the toolbar, so it should).
    .toolbar(removing: .sidebarToggle)
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
  var body: some Scene {
    WindowGroup { RootView() }
  }
}

SpikeApp.main()
