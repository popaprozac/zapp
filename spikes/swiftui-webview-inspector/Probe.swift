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
      List(items, id: \.self, selection: $selection) { Text($0) }
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
