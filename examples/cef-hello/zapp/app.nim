## cef-hello — the minimal fullbleed-web fixture for the CEF
## `webEngine:"chromium"` production slice. One window, one service, one
## button. No sidebar/inspector/toolbar are set on the WindowOptions below —
## that omission (not a config flag) is what makes this window fullbleed-web:
## the CEF window-creation branch (a later task) only supports plain windows
## like this one, not native-chrome-heavy ones.
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
    width: 480, height: 320,
    inspectable: Inspectable.Auto, # web inspector: on in dev, off in prod
  ))
  win.onReady(onReady)

  app.run()

quit(runApp())
