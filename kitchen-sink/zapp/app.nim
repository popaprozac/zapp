## Kitchen-sink, authored in Nim — the idiomatic analog of zapp/app.zc.
## The Nim build (ZAPP_NATIVE_LANG=nim) compiles this as its root; the zc
## build still uses app.zc. greet is a real Nim service handler.
import zapp

proc greet(args: JsonNode): string =
  ## Mirrors app.zc's greet — the real value (no more [object Object]).
  "Hello from Zapp!"

proc onReady(id: cint, handle: pointer) {.cdecl.} =
  ## Mirrors app.zc's on_ready — reveal the window once its webview bridge is up,
  ## so the native-chrome shell never flashes empty. Must be a top-level cdecl
  ## proc (it's registered as a C function pointer); reconstruct the Window from
  ## the (id, handle) the callback receives, just like app.zc's Window{id,handle}.
  Window(id: id, handle: handle).show()

proc runApp(): int =
  let a = newApp("kitchen-sink", terminateAfterLastWindowClosed = true)
  registerService("greet", greet)

  var opts = newWindowOptions("Kitchen Sink")
  opts.visible = false   # deferred show — revealed by onReady when content can paint
  opts.width = 1100
  opts.height = 700
  opts.sidebarUrl = "#sidebar-pane"
  opts.sidebarWidth = 240
  opts.inspectorUrl = "#inspector-pane"
  opts.inspectorWidth = 300
  opts.inspectorCollapsed = true
  # Web Inspector parity: on in dev, off in prod (mirrors the skeleton).
  opts.inspectable = inspectableAuto()
  let win = createWindow(opts)
  win.setOnReady(onReady)

  a.run()

quit(runApp())
