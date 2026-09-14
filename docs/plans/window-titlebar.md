# Window titlebar customization

Status: design checkpoint, 2026-09-14. No titlebar options have been added to
the Z-owned public window API yet. This document separates approved decisions
from the remaining implementation and interaction work.

## Agreed configuration and independence

Use a nested `titleBar` configuration. Native title text visibility is an
independent boolean, defaulting to `true` regardless of the selected style:

```ts
// Agreed authoring shape; implementation follows.
const window = await createWindow({
  title: "Z Notes",
  titleBar: {
    style: "hiddenInset",
    titleVisible: false,
  },
});
```

- `title` remains the actual window title. Hiding its visual label does not
  clear it, and later `setTitle` calls still update that title.
- `titleBar.style` describes chrome/content treatment and preset control layout.
- `titleBar.titleVisible` controls the native title label only.
- Changing the style must not implicitly change title visibility.
- Native control visibility/enabled state is a separate future option, not
  encoded in title visibility or confused with fully frameless windows.
- Omitting `titleBar` should preserve today's ordinary native window.

The research-backed style proposal retains `default`, `hidden`, and
`hiddenInset`: standard chrome; full-size content with transparent titlebar
chrome; and that full-size treatment with an inset native control arrangement.
Both hidden modes retain native controls. Unlike the older preset descriptions,
neither hides native title text unless `titleVisible: false` is supplied.
The inset enhancement is macOS-specific; future Windows/Linux mappings must be
documented and validated, not presented as already implemented parity.

## Prior art and corrections

The older implementation is useful evidence, not an implementation to copy
without validation:

- `native/platform/darwin/window.m` hides title text in both hidden modes.
  Older documentation describing visible text for `hiddenInset` is stale.
- Its compact-toolbar adjustment is guarded by `defined` on an SDK enum value;
  the installed SDK does not define that value as a preprocessor macro. The
  desired inset therefore needs an actual native layout proof, not that guard.
- `bootstrap/webview.ts` implements CSS `--zapp-drag: drag/no-drag`, a
  `data-zapp-drag-region` alias, and distinct `data-zapp-titlebar` behavior.
  The computed CSS value is checked before interactive descendants, allowing
  inherited `drag` to bypass intended automatic button exclusions.
- The old native titlebar double-click path always zooms. The new path should
  honor platform preferences rather than hardcode that choice.
- Existing chrome CSS variables are valuable, but their values must come from
  each window's own measured geometry, converted into its WebView coordinates.

Research: [Electron titlebars](https://www.electronjs.org/docs/latest/tutorial/custom-title-bar),
[Electron drag regions](https://www.electronjs.org/docs/latest/tutorial/custom-window-interactions),
[Wails titlebar presets](https://github.com/wailsapp/wails/blob/master/v3/pkg/application/webview_window_options.go),
[Wails CSS dragging](https://v3.wails.io/features/windows/frameless/),
[Tauri titlebar configuration](https://v2.tauri.app/reference/config/#titlebarstyle),
[Tauri drag regions](https://v2.tauri.app/learn/window-customization/),
[Electrobun windows](https://framework.blackboard.sh/electrobun/apis/browser-window/),
[Electrobun dragging](https://framework.blackboard.sh/electrobun/apis/browser/draggable-regions/).
These frameworks do not all give `hidden` identical control-visibility semantics.

## Bounded implementation sequence

1. Add checked, typed titlebar creation options to the Z and focused TypeScript
   APIs, including the related-window path. Apply native appearance before
   showing a window. Do not add dynamic setters or arbitrary button offsets.
2. Implement the distinct move-only and titlebar-region intents. Retain CSS
   drag/no-drag authoring, with explicit exclusion/interactive-element tests.
   Settle any changed precedence or public marker vocabulary before shipping it.
3. Publish per-window native chrome measurements for frontend layout, including
   related documents. Shared application CSS must not copy owner window geometry
   into a differently sized/styled child.
4. Demonstrate a custom Svelte Notes header with functioning native controls,
   clickable search/actions, drag regions, and the existing smooth resize path.

Acceptance checks include all three styles with title text both visible and
hidden; omitted visibility stays true; title updates do not reveal hidden text;
hidden creation remains hidden; invalid options allocate no native resources;
related windows retain their own chrome configuration; drag exclusions and
unfocused-window gestures work; fullscreen/zoom/close remain correct; and native
controls and layout respond to OS settings. Include bounded native smokes and
user visual review. No ASan runs for this UI slice.

Separate follow-ups: fully frameless windows, individual control options,
arbitrary traffic-light positioning, vibrancy/transparency, and application
toolbars. Related-window injection and advanced stylesheet adapters remain
separate workstreams and do not block this framework feature.
