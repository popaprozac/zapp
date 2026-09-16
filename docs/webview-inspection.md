# WebView inspection

Zapp makes WebViews inspectable by default in development and not inspectable
by default in production. These defaults follow the CLI build mode, not the
page URL or compiler optimization level.

Set the application default in `zapp.config.ts`:

```ts
import { defineConfig } from "@zappdev/cli";

export default defineConfig({
  application: { name: "My App", identifier: "com.example.my-app" },
  // Omit this to use the development/production defaults.
  webview: { inspectable: false },
});
```

Native Z code can override that default when creating an ordinary window:

```zs
import { WindowOptions, Inspectable } from "zapp/window";

const window = try app.windows.create(WindowOptions({
  title: "Diagnostics",
  inspectable: Inspectable.enabled,
}));
```

`Inspectable.auto` is the default and follows configuration.
`Inspectable.enabled` and `Inspectable.disabled` explicitly opt that window in
or out. Inspection exposes page content and JavaScript state, so enable it in a
distributed application only deliberately. Disabling inspection is not a
security boundary for secrets shipped to the frontend.

## macOS behavior

| Build mode | Default | Inspection when enabled | Native Reload menu item |
| --- | --- | --- | --- |
| Development | Enabled | Safari Develop; local Inspect Element when WebKit supports developer extras | Preserved |
| Production | Disabled | Safari Develop through the public WebKit inspection API | Removed |

For Safari inspection, enable Safari's developer features, then select the
application's page from the Develop menu.

The local development convenience uses an **unsupported WebKit preference**.
Zapp checks for its selector and catches preference-setting exceptions; if it
is unavailable, public Safari inspection remains the supported path. The
developer-extras implementation is not emitted into production sources, even
when a production window explicitly enables inspection. This is not a promise
about App Store review or future WebKit behavior.

Production removes only WebKit's native Reload item. Copy, Paste, spelling,
links, and other native contextual actions remain untouched, as do application
context menus. This narrow filter uses a WebKit menu-item identifier rather
than translated text or numeric tags. That identifier is an implementation
detail and is covered by compatibility checks.

## Child windows and authority

Frontend-created ordinary windows inherit their native owner's inspection
policy. Related windows inherit the owner's effective WebView inspectability;
they cannot grant themselves inspection. `inspectable` is not a frontend
`createWindow` or `createRelatedWindow` option, and the native bridge rejects
attempts to supply it.

This is creation-time policy. There is no runtime toggle or programmatic
inspector-opening API in the current tier. Windows and Linux behavior is not
implemented by this macOS path.

## Verification

`bun native/z/testing/webview-inspection.ts` checks actual WebKit instances,
policy resolution, related-view inheritance, native menu filtering, and the
absence of developer-extras code from production output. It exercises Stage 0
and the native compiler at `-O0` and `-O2` with bounded UBSan runs.

For a 60-second visual menu check, add `--interactive=development` or
`--interactive=production`. Development should show Reload and Inspect Element
on blank content; production should show neither. Right-clicking the input
should retain native editing actions in both modes.
