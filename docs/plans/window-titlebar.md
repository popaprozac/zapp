# Window titlebar customization

Status: appearance implementation, 2026-09-14. Typed titlebar creation options
are implemented in the Z and focused TypeScript APIs and both native creation
paths. See the [developer guide](../window-titlebar.md). Drag interactions and
measured CSS geometry remain subsequent slices. The exclusion-first DOM policy
below is approved and implemented in the shared bootstrap resolver.

## Agreed configuration and independence

Use a nested `titleBar` configuration. Native title text visibility is an
independent boolean, defaulting to `true` regardless of the selected style:

```ts
// Implemented for ordinary and related macOS windows.
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

The implemented styles retain `default`, `hidden`, and
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
  The old computed-CSS-first resolver allowed inherited `drag` to bypass
  automatic button exclusions. The shared resolver now closes that gap.
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

1. **Implemented:** checked, typed titlebar creation options in the Z and focused TypeScript
   APIs, including the related-window path. Native appearance is applied before
   showing a window, without dynamic setters or arbitrary button offsets.
2. **Policy implemented; native hookup pending:** distinct move-only and
   titlebar-region intents, using existing markers and CSS drag/no-drag.
   Interactive controls and any no-drag ancestor always win. An explicit
   positive marker cannot turn a button or an excluded subtree into a drag
   handle. The closest positive HTML marker selects titlebar versus move;
   inherited CSS drag does not downgrade a titlebar to move-only.
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

## Appearance checkpoint evidence

- `bun native/z/testing/window-focus.ts --titlebar`: checked defaults, invalid
  bridge options, registry preservation, and title updates, through Stage 0 and
  native lowering at `-O0`/`-O2` with UBSan.
- Add `--native` for the six-case AppKit matrix. All styles retain controls,
  visibility is independent, and creation stays hidden until ordered front.
  This host measured a 9-point control top inset for default/hidden and 19 for
  hiddenInset, with either title visibility. These are observations, not API
  constants or promised cross-OS geometry.
- Existing focus, controls, presentation, registry, events, adoption, and family
  smokes pass in both compiler paths and optimization modes.
- `VITE_ZAPP_STYLE_SMOKE=1 bun cli/src/test-notes-launch-macos.ts packaged`
  and the matching `dev` command pass using real ordinary/related creation.
  Native checks cover independent chrome, hidden publication, and hidden-title
  updates; shared CSS, Svelte, HMR, worker shutdown, and Vite cleanup still pass.
- 298 runtime tests, root TypeScript checks, and Svelte checks pass.
- The probes exposed and closed two upstream Z gaps: enum equality across
  imported spellings, and missing inferred boolean evidence for native enum
  comparisons. No new syntax or production Objective-C shim was needed.

## Drag-policy checkpoint

`bootstrap/window-drag.ts` owns hit classification; it inspects the full composed
event path, including SVG, body/root markers, and open shadow hosts. Interactive
semantics include native controls, links, editable areas, focusable custom
controls and interactive ARIA roles. Closed shadow internals are not visible to
the outer document: an opaque interactive widget must mark its host no-drag.

Verification: 305 runtime tests pass, including the exclusion matrix, detached
documents, and bundled bootstrap reset behavior. TypeScript and Svelte checks
are clean. The packaged and dev `VITE_ZAPP_STYLE_SMOKE=1` launch gates pass real
WebKit checks in the owner and three related documents: inherited CSS, SVG
button content, editing, open shadow roots, style changes and reparenting.
Dev HMR update/prune and Vite port release also pass. These classify DOM hits;
they do not claim a native mouse gesture or custom header is implemented yet.

Legacy hover routing refreshes on mouse-down and clears on mouseleave, blur and
pagehide. This is not sufficient to authorize the new native drag path: tie that
path to an original native mouse-down, document generation and bounded gesture
lifetime. Do not block/pump the main run loop awaiting JavaScript, and do not
silently consume an interactive click based on a stale hover flag.

Native double-click support must account for macOS `Fill` as well as
Zoom/Minimize/None. Chromium currently calls private `_zoomFill:` for Fill; that
is research evidence, not permission to add a private AppKit dependency.
[Chromium implementation](https://chromium.googlesource.com/chromium/src/+/master/components/remote_cocoa/app_shim/native_widget_mac_nswindow.mm).
AppKit's public [performWindowDragWithEvent:](https://developer.apple.com/documentation/appkit/nswindow/performdrag(with:)?language=objc)
accepts the original examined mouse-down and returns immediately; the eventual
mouse-up may not be delivered, so cleanup must not depend solely on mouse-up.

The next checkpoint is the bounded native gesture hookup and per-window layout
insets, followed by the custom Notes header and user visual review.

## Native gesture prototype: upstream deliberation required

The one-shot DOM snapshot component and unit tests now exist in
`bootstrap/window-drag.ts`. It requires a trusted left mouse-down, matching
coordinates/click count, a short age limit, and an unchanged live hit path.
Release prevents move-only dragging; a completed titlebar double-click remains
classifiable. It is not installed in the production bridge yet.

The native integration draft is saved in
[`prototypes/native-window-drag.patch`](prototypes/native-window-drag.patch).
Do not apply it as a working implementation: it did not pass Z checking.
Production native source has been restored to the last working checkpoint.

Confirmed blockers:

- `Option<Weak<MacOSWindowGestures>>` is rejected as a native stored field
  (Z0814: only String, scalars, plain native records and strong imported ObjC
  references are accepted). The observer owns window/view; the window must
  refer back weakly to avoid a retain cycle.
- Every native-subclass method, even a private Z helper, requires a native
  selector. Z-only helper methods need an explicit upstream design decision.

The proposed upstream scope is captured in the Z repository's
`docs/native-subclass-z-state-design.md`: managed Z state plus ordinary private
Z helpers in native subclasses, with native `as` entries retaining their ABI
and receiver guards. No framework-specific registry or raw pointer workaround.

Once approved and implemented upstream, resume by validating native event/input
ordering, callback expiration, document retirement, first-click behavior and
real drags. The prototype's Fill preference branch is incomplete; do not call
its double-click behavior finished. Geometry and the custom Notes header follow.
