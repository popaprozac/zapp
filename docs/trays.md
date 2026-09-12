# Tray menus

Trays are application-owned status items. On macOS they appear in the system
menu bar and use the same `Menu` and `Command` types as application/context menus.
This first surface is native Z; Windows, Linux, and frontend tray bindings are
not implemented yet.

```zs
import { TrayOptions } from "zapp/tray";
import { Menu, MenuItem } from "zapp/menu";
import embed from "std/embed";

const ICON = embed.bytes("./assets/tray.png");

// In your application's main-thread setup; showCommand and quitCommand are
// ordinary Commands, which may also appear in other menus.
const tray = try app.trays.create(TrayOptions({
  icon: ICON,
  template: true,
  tooltip: "My Application",
  menu: Menu({ items: Array<MenuItem>(
    MenuItem.command(showCommand),
    MenuItem.separator,
    MenuItem.command(quitCommand)
  ) }),
}));
```

`create`, `setMenu`, and `setTooltip` throw `TrayError`, with `id` and `message`.
Before `app.run()`, creation registers a definition; native image decoding and
status-item creation happen during startup. Startup failures appear as the
`tray` variant of `ApplicationError`. Creation while running realizes the item
immediately. Invalid replacement menus leave the previous menu in place.

| Operation | Meaning |
|---|---|
| `app.trays.create(options)` | Register and return a `Tray` handle |
| `app.trays.get(id)` | Find a live handle as `Option<Tray>` |
| `app.trays.all()` | Snapshot the current handles |
| `tray.setMenu(menu)` | Replace this presentation, preserving shared commands elsewhere |
| `tray.setTooltip(text)` | Update this status item's tooltip |
| `tray.remove()` | Remove it; repeated removal is harmless |

Operations require `thread.main`. Dropping a local handle does **not** remove
the tray. Application shutdown removes all status items and releases their
connections/subscriptions. Handles retained after removal cannot resurrect an
item. A tray keeps only a weak backreference to its manager.

Menus accept commands, nested submenus, and separators. Application-menu roles,
custom click events, popovers, runtime icon replacement, and frontend-created
trays are later work. A monochrome transparent PNG with `template: true` lets
macOS choose the appropriate appearance. The current renderer fits the image
into an 18-point square inside a 24-point status item.

## Closing windows versus quitting

Creating a tray never changes application lifetime. Opt in explicitly:

```ts
export default defineConfig({
  application: {
    name: "My Application",
    quitOnLastWindowClosed: false,
  },
});
```

The default is `true`. With `false`, closing the last window leaves services,
workers, and trays running; reopening a window remains possible. A windowless
application can also call `app.run()`—no hidden WebView is created. Ensure users
have an obvious Quit command. `Application.current().quit()` uses the ordinary
cancellable application-quit path; it does not bypass shutdown.

See [Z Notes](../spikes/z-notes/README.md#tray-menu) for a runnable example and
[configuration](configuration.md) for the build-time policy.

## Contributor verification

```sh
bun native/z/testing/tray.ts
bun native/z/testing/tray.ts --native
```

Both use hard process deadlines and strict Clang/UBSan at `-O0` and `-O2`.
The first is platform-neutral registry/lifetime coverage through both emitters.
The second briefly creates real AppKit status items using Stage 0 and the
installed native Z driver, then updates/removes them; it requires macOS.
Interactive menu tracking and appearance still require a visual check.
