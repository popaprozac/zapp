# Nim App-Authoring API Shape — Decision Proposal

**Status:** DECIDED — **Shape A (mirror zc)**, 2026-06-17. `app.window.create` / `app.service.add` canonical; free procs survive as unadvertised primitives; handler receives `app`. User rationale: Wails-v3 manager model + web-dev "object-with-methods" familiarity; Nim's UFCS + case-insensitivity make the zc shape nearly free. Implementation plan: `docs/superpowers/plans/2026-06-17-nim-app-api-shape.md`.

**The decision:** As the zc→Nim migration exposes more of the native framework to an app's `zapp/app.nim`, what **shape** should that app-authoring API take — a faithful mirror of zc's `app.zc` surface, or an idiomatic-Nim re-shape? This was triggered by the parity audit (2026-06-17), which found the current Nim app API drifted from zc's shape (free procs vs `app.*` manager methods) without that being a surfaced, deliberate decision.

**North star reminder:** the mandate is to *migrate* the native framework from Zen-C to Nim — a faithful port. Idiomatic-Nim divergence is allowed only when there's a real language nuance/advantage, and only as a deliberate, surfaced choice. So this proposal makes the shape an explicit pick.

**Scope:** this is *only* the API-shape question. Three audit findings are orthogonal and handled separately regardless of this decision:
- Default-value bugs (`acceptFirstMouse`, `autoCenter` flipped vs zc) — fix to match zc.
- Retire leftover `registerSkeletonServices`.
- Parity gaps (Window methods, manager surfaces not yet on `app.nim`) — migration backlog, ported over future cycles.

---

## The two shapes, same app in each

A representative app: a `greet` service, a main window (sidebar, deferred no-flash show), inspectable-in-dev, and one manager call (a dock badge) to show where the shapes differ most.

### zc today (the reference we're migrating from)
```zc
fn greet(app: App*, args: JsonValue*) -> string { return "Hello from Zapp!"; }

fn on_ready(id: int, handle: void*) -> void { Window{id: id, handle: handle}.show(); }

fn run_app() -> int {
    let config = AppConfig{ name: "demo",
        applicationShouldTerminateAfterLastWindowClosed: true,
        webContentInspectable: Zapp::inspectable_auto(), maxWorkers: 0, qjsStackSize: 0 };
    let app = App::new(config);
    app.service.add("greet", greet);
    let opts = WindowOptions::create("Demo");
    opts.visible = false; opts.sidebarUrl = "#sidebar";
    let win = app.window.create(&opts);
    win.on_ready(on_ready);
    app.dock.set_badge("3");
    return app.run();
}
```

### Shape A — Mirror zc (managers on `App`, handler gets `app`)
```nim
import zapp

proc greet(app: App, args: JsonNode): string = "Hello from Zapp!"

proc onReady(id: cint, handle: pointer) {.cdecl.} =
  Window(id: id, handle: handle).show()

proc runApp(): int =
  let app = newApp(AppConfig(
    name: "demo",
    terminateAfterLastWindowClosed: true,
    inspectable: Inspectable.Auto,
  ))
  app.service.add("greet", greet)
  var opts = newWindowOptions("Demo")
  opts.visible = false
  opts.sidebarUrl = "#sidebar"
  let win = app.window.create(opts)
  win.onReady(onReady)
  app.dock.setBadge("3")
  app.run()

quit(runApp())
```

### Shape B — Idiomatic Nim (free procs + methods on returned objects) — *current direction*
```nim
import zapp

proc greet(args: JsonNode): string = "Hello from Zapp!"

proc onReady(id: cint, handle: pointer) {.cdecl.} =
  Window(id: id, handle: handle).show()

proc runApp(): int =
  let app = newApp("demo", terminateAfterLastWindowClosed = true)
  registerService("greet", greet)
  var opts = newWindowOptions("Demo")
  opts.visible = false
  opts.sidebarUrl = "#sidebar"
  opts.inspectable = inspectableAuto()
  let win = createWindow(opts)
  win.setOnReady(onReady)
  setDockBadge("3")
  app.run()

quit(runApp())
```

---

## Tradeoffs

| Dimension | A — Mirror zc | B — Idiomatic free procs |
|---|---|---|
| **Faithful migration** | ✅ reads as a 1:1 port of app.zc | ⚠️ deliberate divergence (the thing that triggered this) |
| **Muscle memory** (anyone who knew zc) | ✅ `app.window.create`, `app.service.add` identical | ❌ must relearn free-proc names |
| **Discoverability** | ✅ `app.` autocompletes the whole surface, grouped (window/service/dock/tray/…) | ❌ flat free procs; no grouping |
| **Handler can reach the app** | ✅ `app` param (call other services, windows, managers; testable) | ❌ needs a global `activeApp` to reach app from a handler |
| **Ceremony** | slightly more — `App` carries manager objects; handlers thread `app` even if unused | less — bare procs |
| **"Idiomatic Nim"** | still fine (UFCS makes `app.window.create` natural); managers are just fields | marginally more Nim-native |
| **Refactor cost now** | higher — add `App.window/service/…` manager objects, rethread handler sig | none (already there) |

### Nim-specific facts that matter
- **Nim identifiers are case/underscore-insensitive** (after the first char): `onReady` ≡ `on_ready`, `setBadge` ≡ `set_badge`. So zc's snake_case method names work *verbatim* in Nim app code — **the naming divergence (`setOnReady` vs `on_ready`, etc.) essentially evaporates under Shape A**; both spellings compile to the same call. We just standardize the *canonical* spelling in docs.
- **UFCS** means `app.window.create(opts)` is just `create(app.window, opts)` — no OO machinery needed; `app.window` is a plain field holding a small manager object (same as zc's `WindowManager` field).
- **Handler `app` param**: Shape A threads it (explicit, testable); Shape B would add a module-global `activeApp` so a free-proc handler can still reach windows/managers. Threading is cleaner.

---

## Recommendation

**Shape A (mirror zc), with Nim-idiomatic spelling.** Rationale: the whole point of this track is a faithful zc→Nim *migration*; Shape A makes app.nim read as a direct port of app.zc (`app.service.add`, `app.window.create`, `app.dock.setBadge`, `handler(app, args)`), which is the strongest guard against silent drift and the best muscle-memory parity. Nim's case-insensitivity + UFCS mean we get that 1:1 shape *without* fighting the language — the earlier "free procs are more idiomatic" reasoning doesn't really hold once UFCS is in play. The cost is a one-time refactor (give `App` its `window`/`service`/… manager fields and thread `app` through handlers), which also sets up the clean home for the parity-gap surfaces (dock/tray/menu/…) as they're ported.

Pick B only if we explicitly want to lean into a Nim-native re-shape and accept documenting it as a deliberate divergence from zc.

## If A is chosen — the refactor (separate plan)
1. `App` gains manager fields: `window`, `service`, and (as they're ported) `dock`/`tray`/`menu`/`dialog`/`notification`/`sync`/`fs`/`security` — each a thin Nim object whose methods call the existing procs.
2. Service handler signature → `proc(app: App, args: JsonNode): string`; `registerService` becomes `app.service.add`.
3. `newApp` accepts an `AppConfig` (surface `inspectable`/`maxWorkers`/qjsStackSize) — keep the `newApp(name)` shorthand as a convenience overload.
4. `createWindow`→`app.window.create`; `Window.show/setOnReady` stay methods (already are).
5. Update kitchen-sink `app.nim`, the `zapp init` scaffold, and docs. Both builds + tsc + tests green.
6. (Bundle in the orthogonal fixes: default-value bugs, retire `registerSkeletonServices`.)

## Verification
A trivial decision doc — no build impact. Once a shape is chosen, the refactor lands under subagent-driven execution with the usual gates.
