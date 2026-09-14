# Window titlebars

Choose native chrome independently from native title-text visibility. These
creation options are implemented on macOS for ordinary and related windows.

```ts
import { createWindow, createRelatedWindow } from "@zappdev/runtime/window";

const main = await createWindow({
  title: "Workspace",
  titleBar: { style: "hiddenInset", titleVisible: false },
});

const inspector = await createRelatedWindow({
  title: "Inspector",
  visible: false,
  titleBar: { style: "default", titleVisible: true },
});
// Mount into inspector.document, then present it.
inspector.show();
```

| `titleBar.style` | macOS behavior |
| --- | --- |
| `default` | Ordinary native chrome; content below the titlebar. |
| `hidden` | Full-size content behind a transparent titlebar; native controls retained. |
| `hiddenInset` | Full-size content with transparent titlebar and inset native controls, laid out by AppKit. |

`style` defaults to `default`. `titleVisible` defaults to `true` in **every**
style. “Hidden” describes the chrome treatment, not automatic title or control
removal. Omitting `titleBar` preserves the ordinary native window.

`titleVisible: false` hides only the native label. The actual window title is
still present for native window management. `window.setTitle("Updated")`
updates it without revealing the label. `visible: false` remains independent:
appearance is applied before showing, and hidden creation stays hidden.

The same options are available to native Z applications:

```zs
import { WindowOptions, TitleBarOptions, TitleBarStyle } from "zapp/window";

const window = try app.windows.create(WindowOptions({
  title: "Workspace",
  titleBar: TitleBarOptions({
    style: TitleBarStyle.hiddenInset,
    titleVisible: false,
  }),
}));
```

Window creation remains main-thread work and requires the usual authority.
Frontend options are validated in TypeScript and again at the native bridge;
unknown styles, misspelled nested keys, and invalid value types are rejected
before allocating a window. Related windows choose their own titlebar; neither
owner chrome nor owner geometry is inherited through shared CSS.

## Current boundaries

These are creation options, not dynamic setters. No arbitrary control offsets,
fully frameless mode, application toolbars, or control-removal options are
implied. The inset preset uses an internal empty native toolbar for AppKit layout;
it is not a user-configurable application toolbar API.

Full-size content can extend under native controls and title text. The shared
DOM resolver now follows the approved drag-region rules below; connecting it to
native gestures and publishing per-window CSS insets remain the next slice.
Until then, keep important content clear of that area; do not treat a
fixed padding value as a cross-platform geometry guarantee. Ordinary native
chrome remains the default. Windows/Linux appearance mappings are not yet
implemented in this path.

## Custom header interaction contract

The following markup is the approved contract, not yet a complete native drag
feature in the current macOS backend:

```html
<header data-zapp-titlebar>
  <span>Z Notes</span>
  <input placeholder="Search notes">
  <button>New note</button>
</header>
```

- `data-zapp-titlebar` selects dragging and native titlebar double-click behavior.
- `data-zapp-drag-region` or `--zapp-drag: drag` selects move-only behavior.
- Interactive controls and `--zapp-drag: no-drag` always exclude dragging, even
  when nested inside a marked region. No force-draggable buttons are supported.
- A custom clickable widget without native/ARIA interactive semantics should use
  `--zapp-drag: no-drag`. This also applies to a closed-shadow widget's host,
  whose internals are not exposed in the document's event path.

Exclusion applies to the subtree: nesting another drag marker inside a no-drag
region does not opt it back in. For nested positive HTML markers, the closest
one chooses the intent. CSS custom properties inherit; inherited `drag` does not
turn a titlebar into a move-only region or bypass a control's exclusion.
