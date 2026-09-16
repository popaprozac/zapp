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
  resizable: false,
  maximizable: false,
  fullscreenable: false,
  titleBar: { style: "hiddenInset", titleVisible: false },
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

## Layout around native chrome

Zapp sets two CSS custom properties on each document's root:

- `--zapp-titlebar-height`: top content overlap in viewport CSS pixels. Zero
  for ordinary content below native chrome, not the physical titlebar height.
- `--zapp-window-controls-inset-left`: the horizontal space occupied by the
  native controls inside this viewport, measured from its left edge. Add your
  own design spacing after that edge.

The values come from native layout, not fixed offsets. They are initialized
before related-window publication and refreshed at document binding, resizing,
and fullscreen completion. They are local to each document; selecting them in
`theme.variables` is rejected so an owner's geometry cannot overwrite a child.

To keep an entire page below the chrome:

```css
main { padding-top: calc(var(--zapp-titlebar-height, 0px) + 16px); }
```

Or place a header beside the native controls and start other content below it:

```css
.custom-header {
  min-height: max(64px, var(--zapp-titlebar-height, 0px));
  padding-left: calc(var(--zapp-window-controls-inset-left, 0px) + 16px);
}
```

## Resizing and presentation policy

`resizable`, `maximizable`, and `fullscreenable` are independent creation
options, each defaulting to `true`. They apply to ordinary and related windows
and to Z's `WindowOptions`. `resizable` controls interactive edge resizing;
`maximizable` permits zoom/maximize; `fullscreenable` permits native fullscreen
entry. The operating system still determines supported presentation behavior.

Disallowed maximize/fullscreen requests are no-ops, including native actions,
not just disabled frontend controls. Leaving fullscreen remains possible.
These are presentation policies, not security capabilities. The inspector
example disables all three; other windows retain their defaults.

## Current boundaries

These are creation options, not dynamic setters. No arbitrary control offsets,
fully frameless mode, application toolbars, or control-removal options are
implied. The inset preset uses an internal empty native toolbar for AppKit layout;
it is not a user-configurable application toolbar API.

Full-size content can extend under native controls and title text. The shared
DOM resolver and native gesture hookup now follow the approved rules below;
real drag validation and complete double-click preferences remain unfinished.
Use the measured insets above rather than treating fixed padding as a
cross-platform geometry guarantee. Ordinary native
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
