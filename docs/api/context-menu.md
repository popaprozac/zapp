# ContextMenu API

> **Status:** Implemented on macOS. Windows implementation in progress.

The ContextMenu API lets you show native context menus from JavaScript, replacing or augmenting the default right-click menu.

## Import

```ts
import { ContextMenu } from "@zapp/runtime";
```

## Default Behavior

Without any JavaScript, right-click shows a **filtered native context menu**:
- Text editing items (Copy, Cut, Paste, Select All) are preserved
- Browser items (Reload, Back, Forward) are removed
- "Inspect Element" appears only when dev tools are enabled

## Custom Context Menu

Use the standard DOM `contextmenu` event with `ContextMenu.show()`:

```ts
document.addEventListener("contextmenu", (e) => {
    e.preventDefault(); // suppress the filtered default

    ContextMenu.show([
        { role: "copy" },
        { role: "paste" },
        { type: "separator" },
        { label: "Custom Action", action: () => console.log("clicked!") },
    ]);
});
```

## API

### `ContextMenu.show(items: MenuItemDef[])`

Shows a native context menu at the current cursor position. Uses the same `MenuItemDef` type as the [Menu API](menu.md).

Supports: `label`, `role`, `type`, `action`, `enabled`, `checked`, `accelerator`, `submenu`.

## Scenarios

| Scenario | Code |
|---|---|
| Default (no code) | Filtered native menu (Copy/Paste, no Reload) |
| Custom menu | `e.preventDefault()` + `ContextMenu.show([...])` |
| No menu | `e.preventDefault()` only |

## Roles

Item-level roles use native clipboard/editing commands:

| Role | Action |
|---|---|
| `"copy"` | Copy selection |
| `"cut"` | Cut selection |
| `"paste"` | Paste from clipboard |
| `"selectAll"` | Select all content |
| `"undo"` | Undo last action |
| `"redo"` | Redo last undone action |

## Platform Notes

| | macOS | Windows |
|---|---|---|
| Default menu filtering | `willOpenMenu:` override on WKWebView | `ContextMenuRequested` event (in progress) |
| Custom menu rendering | `NSMenu popUpMenuPositioningItem:` | `TrackPopupMenu` (in progress) |
| Position | CSS client coordinates | CSS client coordinates |
