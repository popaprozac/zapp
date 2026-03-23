# Menu API

The `Menu` module builds native application menus and context menus. Menus are defined declaratively with a tree of items and can include keyboard accelerators, role-based system items, and inline action handlers.

## Import

```typescript
import { Menu } from "@zapp/runtime";
```

## Methods

| Method | Signature | Description |
|--------|-----------|-------------|
| `Menu.build` | `(items: MenuItemDef[]) => MenuHandle` | Builds a native menu from a declarative item tree and returns a handle. |

## MenuHandle

| Method | Signature | Description |
|--------|-----------|-------------|
| `on` | `(id: string, handler: () => void) => void` | Registers a click handler for the menu item with the given `id`. |

## Types

### MenuItemDef

```typescript
interface MenuItemDef {
  id?: string;
  label?: string;
  type?: "normal" | "separator" | "checkbox";
  enabled?: boolean;
  checked?: boolean;
  accelerator?: string;
  role?: string;
  action?: () => void;
  submenu?: MenuItemDef[];
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `id` | `string` | `undefined` | Unique identifier used with `menu.on(id, handler)`. |
| `label` | `string` | `""` | Display text. Ignored for separators and role-based items. |
| `type` | `"normal" \| "separator" \| "checkbox"` | `"normal"` | The kind of menu item. |
| `enabled` | `boolean` | `true` | Whether the item is clickable. |
| `checked` | `boolean` | `false` | Check state for `checkbox` type items. |
| `accelerator` | `string` | `undefined` | Keyboard shortcut string. See [Accelerator Format](#accelerator-format). |
| `role` | `string` | `undefined` | A system-defined role. Overrides label and action. See [Roles](#roles). |
| `action` | `() => void` | `undefined` | Inline click handler. Alternative to `menu.on()`. |
| `submenu` | `MenuItemDef[]` | `undefined` | Nested menu items. Makes this item a submenu parent. |

## Roles

Roles let you insert standard platform menu items without defining labels or actions manually.

### Menu-level roles

Use these as the `role` on a top-level menu item (one with a `submenu` or acting as a submenu group):

| Role | Description |
|------|-------------|
| `"appMenu"` | The standard application menu (macOS only: app name, About, Hide, Quit). |
| `"editMenu"` | Standard Edit menu (Undo, Redo, Cut, Copy, Paste, Select All). |
| `"windowMenu"` | Standard Window menu (Minimize, Zoom, etc.). |

### Item-level roles

Use these on individual `MenuItemDef` entries:

| Role | Accelerator (auto) | Description |
|------|---------------------|-------------|
| `"copy"` | Cmd/Ctrl+C | Copy selection. |
| `"cut"` | Cmd/Ctrl+X | Cut selection. |
| `"paste"` | Cmd/Ctrl+V | Paste from clipboard. |
| `"selectAll"` | Cmd/Ctrl+A | Select all. |
| `"undo"` | Cmd/Ctrl+Z | Undo last action. |
| `"redo"` | Cmd/Ctrl+Shift+Z | Redo last undone action. |

## Accelerator Format

Accelerators are strings that describe keyboard shortcuts. Modifiers are joined with `+`.

| Token | macOS | Windows/Linux |
|-------|-------|---------------|
| `CmdOrCtrl` | Cmd | Ctrl |
| `Cmd` | Cmd | (not available) |
| `Ctrl` | Ctrl | Ctrl |
| `Shift` | Shift | Shift |
| `Alt` | Option | Alt |

Combine with a key name: letter keys (`A`-`Z`), function keys (`F1`-`F12`), or special keys (`Enter`, `Escape`, `Tab`, `Space`, `Backspace`, `Delete`, `Up`, `Down`, `Left`, `Right`).

**Examples:**

| Accelerator | Description |
|-------------|-------------|
| `"CmdOrCtrl+S"` | Save |
| `"CmdOrCtrl+Shift+S"` | Save As |
| `"Shift+Alt+T"` | Custom shortcut |
| `"F11"` | Single key |
| `"CmdOrCtrl+Shift+Z"` | Redo |

## Examples

### Full application menu

```typescript
import { App } from "@zapp/runtime";
import { Menu } from "@zapp/runtime";

const menu = Menu.build([
  { role: "appMenu" },
  {
    label: "File",
    submenu: [
      { label: "New", accelerator: "CmdOrCtrl+N", id: "file-new" },
      { label: "Open...", accelerator: "CmdOrCtrl+O", id: "file-open" },
      { type: "separator" },
      { label: "Save", accelerator: "CmdOrCtrl+S", id: "file-save" },
      { label: "Save As...", accelerator: "CmdOrCtrl+Shift+S", id: "file-save-as" },
      { type: "separator" },
      { label: "Quit", accelerator: "CmdOrCtrl+Q", action: () => App.quit() },
    ],
  },
  { role: "editMenu" },
  {
    label: "View",
    submenu: [
      { label: "Toggle Fullscreen", accelerator: "F11", id: "view-fullscreen" },
      {
        label: "Theme",
        submenu: [
          { label: "Light", id: "theme-light", type: "checkbox", checked: true },
          { label: "Dark", id: "theme-dark", type: "checkbox", checked: false },
        ],
      },
    ],
  },
  { role: "windowMenu" },
]);

App.setMenu(menu);
```

### Inline action handlers

```typescript
const menu = Menu.build([
  {
    label: "File",
    submenu: [
      {
        label: "Export PDF",
        accelerator: "CmdOrCtrl+E",
        action: () => {
          exportAsPDF();
        },
      },
    ],
  },
]);
```

### Using `menu.on()` for explicit listeners

```typescript
const menu = Menu.build([
  {
    label: "File",
    submenu: [
      { label: "New", accelerator: "CmdOrCtrl+N", id: "new" },
      { label: "Open...", accelerator: "CmdOrCtrl+O", id: "open" },
    ],
  },
]);

menu.on("new", () => {
  createNewDocument();
});

menu.on("open", () => {
  openFilePicker();
});

App.setMenu(menu);
```

## Platform Notes

- **macOS**: The first menu is always the application menu. Use `{ role: "appMenu" }` to get the standard About/Hide/Quit items, or define your own.
- **Windows/Linux**: There is no separate application menu. The `"appMenu"` role is ignored on these platforms.
- Accelerators using `Cmd` only work on macOS. Use `CmdOrCtrl` for cross-platform shortcuts.
