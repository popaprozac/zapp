## cef-hello — the render+bridge smoke target for the CEF
## `webEngine:"chromium"` production slice. One service, one button, TWO
## windows (sub-cycle B: proves the slot<->browser registry — see win2
## below). Sub-cycle C1: window 1 now has a `sidebar`, so it exercises the
## NSSplitViewController pane-mounting CEF branch (window.m) — TWO CEF
## browsers (host + sidebar pane), both registered in zapp_cef_browsers[].
## Window 2 stays plain/fullbleed (no sidebar/inspector/toolbar), proving the
## fullbleed CEF branch (window.m's `!useSidebar && !useInspector` path)
## still works unchanged alongside the new sidebar path. Sub-cycle C2: window
## 1 now ALSO has an `inspector`, so it is a 3-pane CEF window (sidebar +
## host + inspector). Window 2 stays plain/fullbleed. Sub-cycle C3 (SPIKE):
## window 1 now ALSO has a `toolbar` (mirrors kitchen-sink's create-time
## shape) — probes whether NSToolbar attach + toolbar-click fan-out +
## toggleSidebar/toggleInspector + trackingSeparator + the WK-only
## `zapp_toolbar_inject_metrics` CSS var all behave on a CEF window. See
## .superpowers/sdd/c3-spike-report.md for findings.
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
  # DevTools (sub-cycle D) is dev-gated on the APP-level inspectable
  # (app_get_bootstrap_web_content_inspectable). Inspectable.Auto is dev-only, so
  # a `bun run build` (prod) app resolves it to false and DevTools can't open.
  # This fixture opts into Inspectable.On so DevTools is exercisable in the built
  # app — a devtools-demo fixture should always be inspectable.
  let app = newApp(AppConfig(name: "cef-hello", terminateAfterLastWindowClosed: true,
                             inspectable: Inspectable.On, maxWorkers: 0))
  app.service.add("greet", greet)

  let win = app.window.create(WindowOptions(
    title: "CEF Hello",
    visible: false,               # deferred show — revealed by onReady
    width: 900, height: 400,      # room for all 3 panes: host + sidebar + inspector
    inspectable: Inspectable.Auto, # web inspector: on in dev, off in prod
    sidebar: SidebarOptions(url: "#sidebar-pane", title: "CEF Sidebar",
                            width: 240, minWidth: 150, maxWidth: 320,
                            presentation: SidebarPresentation.Default),
    inspector: InspectorOptions(url: "#inspector-pane", title: "CEF Inspector",
                                width: 240, minWidth: 180, maxWidth: 320),
    toolbar: ToolbarOptions(items: @[
      ToolbarItemOpt(`type`: "toggleSidebar"),
      # pane:"sidebar" + POSITIONED before the sidebar trackingSeparator ⇒ this
      # item renders in the sidebar's toolbar region (Safari/Mail model), the
      # same convention kitchen-sink's `compose` item uses.
      ToolbarItemOpt(`type`: "button", id: "ping", label: "Ping", icon: "sf:bell", pane: "sidebar"),
      ToolbarItemOpt(`type`: "trackingSeparator", pane: "sidebar"),
      ToolbarItemOpt(`type`: "toggleInspector"),
    ]),
    # C3 gate B: the trackingSeparator only anchors to the sidebar↔content
    # divider under the UNIFIED hidden chrome (FullSizeContentView + transparent
    # titlebar). An UNSET titleBarStyle resolves to a STANDARD titlebar (visible
    # title, non-unified toolbar), where the separator can't align to the split —
    # the same on WK and CEF. Opt into the Mail/Messages look explicitly, exactly
    # as the known-good kitchen-sink reference does (kitchen-sink/zapp/app.nim).
    titleBarStyle: TitleBarStyle.HiddenInset,
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
