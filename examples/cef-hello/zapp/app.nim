## cef-hello — the render+bridge smoke target for the CEF
## `webEngine:"chromium"` production slice. One service, one button, TWO
## windows (sub-cycle B: proves the slot<->browser registry — see win2
## below). Sub-cycle C1: window 1 now has a `sidebar`, so it exercises the
## NSSplitViewController pane-mounting CEF branch (window.m) — TWO CEF
## browsers (host + sidebar pane), both registered in zapp_cef_browsers[].
## Window 2 stays plain/fullbleed (no sidebar/inspector/toolbar), proving the
## fullbleed CEF branch (window.m's `!useSidebar && !useInspector` path)
## still works unchanged alongside the new sidebar path. Inspector-on-CEF is
## sub-cycle C2 — neither window sets one yet.
import zapp

proc greet(app: App, args: JsonNode): string =
  ## Round-tripped by src/main.ts's button via `Services.invoke("greet", {name})`.
  ## `{}` (not `[]`) is std/json's safe accessor — returns nil instead of
  ## raising when the key is absent, which getStr's `default` then covers.
  let name = args{"name"}.getStr("World")
  "Hello from " & name

proc onReady(id: cint, handle: pointer) {.cdecl.} =
  ## Reveal the window once its webview bridge is up (no empty-window flash).
  ## Must be a top-level cdecl proc — it's registered as a C function pointer.
  Window(id: id, handle: handle).show()

proc runApp(): int =
  let app = newApp("cef-hello", terminateAfterLastWindowClosed = true)
  app.service.add("greet", greet)

  let win = app.window.create(WindowOptions(
    title: "CEF Hello",
    visible: false,               # deferred show — revealed by onReady
    width: 640, height: 360,      # widened so host + sidebar both have room
    inspectable: Inspectable.Auto, # web inspector: on in dev, off in prod
    sidebar: SidebarOptions(url: "#sidebar-pane", title: "CEF Sidebar",
                            width: 240, minWidth: 150, maxWidth: 320,
                            presentation: SidebarPresentation.Default),
  ))
  win.onReady(onReady)

  ## Sub-cycle B fixture: a SECOND CEF window, same page. Proves the
  ## slot<->browser registry — both windows tick from the same `ticker`
  ## worker broadcast, and each window's "Say hello" click routes its
  ## `greet` invoke result back to ONLY that window (targeted eval by slot),
  ## not both.
  let win2 = app.window.create(WindowOptions(
    title: "CEF Hello — Window 2",
    visible: false,
    width: 480, height: 320,
    x: 560, y: 100,             # offset so it doesn't fully overlap window 1
    inspectable: Inspectable.Auto,
  ))
  win2.onReady(onReady)

  app.run()

quit(runApp())
