## Kitchen-sink, authored in Nim — the idiomatic analog of zapp/app.zc.
## The Nim build (ZAPP_NATIVE_LANG=nim) compiles this as its root; the zc
## build still uses app.zc. greet is a real Nim service handler.
import zapp

# Web-inspector dev gate (C-ABI getter generated into .zapp/zapp_build_config;
# zapp.nim declares the same importc privately, so redeclare it here).
proc zapp_build_dev_tools_default(): cint {.importc, cdecl.}

proc greet(args: JsonNode): string =
  ## Mirrors app.zc's greet — the real value (no more [object Object]).
  "Hello from Zapp!"

proc onReady(id: cint, handle: pointer) {.cdecl.} =
  ## Mirrors app.zc's on_ready — reveal the window once its webview bridge is up,
  ## so the native-chrome shell never flashes empty. Must be a top-level cdecl
  ## proc (it's registered as a C function pointer).
  showWindow(handle)

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
  opts.inspectable = (if zapp_build_dev_tools_default() > 0: TriState.On else: TriState.Off)
  let win = createWindow(opts)
  win.setOnReady(onReady)

  a.run()

quit(runApp())
