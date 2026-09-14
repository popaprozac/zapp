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

Full-size content can extend under native controls and title text. Custom drag
regions and measured per-window CSS layout insets are the next implementation
slice. Until then, keep important content clear of that area; do not treat a
fixed padding value as a cross-platform geometry guarantee. Ordinary native
chrome remains the default. Windows/Linux appearance mappings are not yet
implemented in this path.
