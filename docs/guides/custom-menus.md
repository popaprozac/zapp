# Custom Menus

Zapp provides default application menus (App, Edit, View, Window) out of the box. You can replace them with custom menus using the Menu API.

## Application Menu

### Default menus (no code needed)

When you don't call `Menu.build()`, Zapp creates standard menus:
- **App menu** (macOS): About, Hide, Quit with standard shortcuts
- **Edit**: Undo, Redo, Cut, Copy, Paste, Select All
- **View**: Enter Full Screen
- **Window**: Minimize, Zoom, Close

### Custom menus

```ts
import { Menu, App } from "@zapp/runtime";

Menu.build([
    { role: "appMenu" },  // standard App menu (macOS only)
    { label: "File", submenu: [
        { label: "New", accelerator: "CmdOrCtrl+N", action: () => createNewDoc() },
        { label: "Open...", accelerator: "CmdOrCtrl+O", action: () => openFile() },
        { type: "separator" },
        { label: "Quit", accelerator: "CmdOrCtrl+Q", action: () => App.quit() },
    ]},
    { label: "Edit", role: "editMenu" },  // standard Edit items
    { label: "Tools", submenu: [
        { label: "Run", accelerator: "CmdOrCtrl+R", action: () => run() },
        { label: "Debug Mode", type: "checkbox", checked: false, action: () => toggleDebug() },
    ]},
    { label: "Window", role: "windowMenu" },
]);
```

### Menu item properties

| Property | Type | Description |
|---|---|---|
| `id` | `string` | Unique identifier for event-based listeners |
| `label` | `string` | Display text |
| `type` | `"normal" \| "separator" \| "checkbox"` | Item type (default: `"normal"`) |
| `enabled` | `boolean` | Clickable state (default: `true`) |
| `checked` | `boolean` | For checkbox items (default: `false`) |
| `accelerator` | `string` | Keyboard shortcut |
| `role` | `string` | Built-in role (see below) |
| `action` | `() => void` | Inline click handler |
| `submenu` | `MenuItemDef[]` | Nested items |

### Roles

**Menu-level roles** (expand to standard menus):
- `"editMenu"` — Undo, Redo, Cut, Copy, Paste, Select All
- `"windowMenu"` — Minimize, Zoom, Close
- `"appMenu"` — About, Hide, Quit (macOS only)

**Item-level roles** (single native actions):
- `"copy"`, `"cut"`, `"paste"`, `"selectAll"`, `"undo"`, `"redo"`

### Accelerator format

Use `CmdOrCtrl` for cross-platform shortcuts (Cmd on macOS, Ctrl on Windows):

| Accelerator | macOS | Windows |
|---|---|---|
| `"CmdOrCtrl+S"` | Cmd+S | Ctrl+S |
| `"CmdOrCtrl+Shift+N"` | Cmd+Shift+N | Ctrl+Shift+N |
| `"Alt+F4"` | Option+F4 | Alt+F4 |
| `"F11"` | F11 | F11 |

### Event-based listeners

Instead of inline `action`, use `menu.on()`:

```ts
const menu = Menu.build([
    { label: "File", submenu: [
        { id: "save", label: "Save", accelerator: "CmdOrCtrl+S" },
    ]},
]);

menu.on("save", () => {
    saveDocument();
});
```

## Context Menus

> **Note:** Context menu support is in development. The API shape is documented here for reference.

### Default behavior

Right-click shows a filtered native context menu — text editing items (Copy/Paste) without browser items (Reload/Back/Forward). In dev mode, "Inspect Element" is included.

### Custom context menu

```ts
import { ContextMenu } from "@zapp/runtime";

document.addEventListener("contextmenu", (e) => {
    e.preventDefault(); // suppress the default

    ContextMenu.show([
        { role: "copy" },
        { role: "paste" },
        { type: "separator" },
        { label: "Custom Action", action: () => doSomething() },
    ]);
});
```

### Three scenarios

1. **Do nothing** — users get the filtered default menu (Copy/Paste, no Reload)
2. **`preventDefault()` + `ContextMenu.show()`** — your custom menu
3. **`preventDefault()` only** — no menu at all
