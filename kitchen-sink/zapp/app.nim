## Kitchen-sink, authored in Nim — the idiomatic analog of zapp/app.zc.
## The Nim build (ZAPP_NATIVE_LANG=nim) compiles this as its root; the zc
## build still uses app.zc. greet is a real Nim service handler.
import zapp

proc greet(app: App, args: JsonNode): string =
  ## Mirrors app.zc's greet — the real value (no more [object Object]).
  "Hello from Zapp!"

proc openInfoWindow(app: App, args: JsonNode): string =
  ## App-using service — opens a window. Only safe via the async (main-thread)
  ## worker invoke path; would crash on the sync (nil-app) path.
  discard app.window.create(WindowOptions(title: "Opened from a worker", width: 380, height: 220))
  "opened"

proc onReady(id: cint, handle: pointer) {.cdecl.} =
  ## Mirrors app.zc's on_ready — reveal the window once its webview bridge is up,
  ## so the native-chrome shell never flashes empty. Must be a top-level cdecl
  ## proc (it's registered as a C function pointer); reconstruct the Window from
  ## the (id, handle) the callback receives, just like app.zc's Window{id,handle}.
  Window(id: id, handle: handle).show()

proc runApp(): int =
  let app = newApp("kitchen-sink", terminateAfterLastWindowClosed = true)
  app.service.add("greet", greet)
  app.service.add("openInfoWindow", openInfoWindow)

  let win = app.window.create(WindowOptions(
    title: "Kitchen Sink",
    visible: false,            # deferred show — revealed by onReady
    width: 1100, height: 700,
    sidebar: SidebarOptions(url: "#sidebar-pane", width: 300, minWidth: 150, maxWidth: 500, presentation: SidebarPresentation.Default),
    inspector: InspectorOptions(url: "#inspector-pane", width: 300, collapsed: true),
    inspectable: Inspectable.Auto,
    # Opt into the modern hidden unified chrome explicitly (the full-bleed tiled
    # Mail/Messages look). With the 2c change, an UNSET titleBarStyle now resolves
    # to `default` (standard titlebar) — apps choose the hidden look on purpose.
    titleBarStyle: TitleBarStyle.HiddenInset,
    vibrancy: Material.Sidebar,
  ))
  win.onReady(onReady)

  app.run()

quit(runApp())
