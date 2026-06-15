# Window `backgroundColor` — Apple Parity (macOS + iOS)

**Date:** 2026-06-15
**Branch:** `feat/window-bgcolor-apple`
**Status:** Approved

## Goal

Apply the existing `backgroundColor: "#rrggbb"` window option on macOS and
iOS. The option is already carried through shared `native/window/window.zc`
(`wopts_background_color` accessor + JSON parse) and declared in
`runtime/window.ts`, but only Windows reads it today (seeds WebView2's
`DefaultBackgroundColor`). This wires the Apple side.

## Motivation (and the platform nuance)

On **Windows**, WebView2's repaint visibly **lags during live window resize**,
exposing the webview's default (white) background as a flash against a dark UI
— that's the bug that motivated the option, and why Windows seeds the WebView2
background color.

On **macOS**, WKWebView repaints fast enough that the resize gap is
brief-to-negligible — so on Apple this is primarily **parity + customization**:
let an app choose the window's background color (shown before the page's first
paint, and behind any transient gap) rather than a fix for a visible
resize flash. Code comments must say this — do NOT imply macOS shares
WebView2's slow-resize-repaint problem.

The page's own CSS background always paints over this color; it only fills what
the webview shows *before* the page renders (and any momentary gap).

## Scope

macOS **and** iOS (full parity). Create-time only (mirrors Windows and the
option's nature). Hex `#rrggbb` only (mirrors Windows). No runtime setter, no
named colors.

## Shared layer

No change. `wopts_background_color(opts)` already returns the stored
`"#rrggbb"` string (empty when unset). Only the `runtime/window.ts` docstring
is updated (it currently says "iOS/macOS: not yet wired (no-op)").

## macOS — `native/platform/darwin/window.m`

During window construction, read `wopts_background_color(opts)` and parse
`#rrggbb` with the same validation Windows uses (`bg[0]=='#' && strlen>=7`,
`sscanf(bg+1, "%2x%2x%2x", &r,&g,&b)==3`) into an sRGB `NSColor`
(`colorWithSRGBRed:…/255.0 …alpha:1`).

Apply **only on opaque windows** — skip when `wopts_transparent(opts)` OR
vibrancy is set (`wopts_vibrancy(opts)` non-empty); those modes intentionally
own a clear/material background and an opaque color would fight them:

1. `[window setBackgroundColor:bg]` — replaces the `windowBackgroundColor`
   default currently set at window.m:611 (the window's own backing, shown in
   any transient gap).
2. `mainWebviewRef.underPageBackgroundColor = bg` — guarded
   `if (@available(macOS 12.0, *))`; the direct analogue of WebView2's
   `DefaultBackgroundColor` (the pre-render / overscroll fill). `mainWebviewRef`
   exists in BOTH the plain (`else if (useVibrancy)` / single-webview) and the
   split (sidebar/inspector) construction paths — apply in both. (In the split
   path the window is opaque by construction unless transparent/vibrancy, same
   gate.)

A small file-static helper `zapp_parse_hex_color(const char* hex, int* r, int*
g, int* b) -> bool` keeps the parse in one place.

## iOS — `native/platform/ios/window.m`

iOS materializes the real `UIWindow`/`UIViewController`/`WKWebView` lazily from
a `ZappIOSDeferred` struct (the scene isn't ready at `darwin_window_create`
time). Thread the color through:

1. Add a `char bg_color[8]` (or a parsed `int bg_r/bg_g/bg_b; bool has_bg`)
   field to `ZappIOSDeferred`, populated from `wopts_background_color` in
   `darwin_window_create` (parse there with the same helper).
2. At materialization, when set, replace `systemBackgroundColor` on
   `window.backgroundColor` and `root.view.backgroundColor` with the parsed
   `UIColor` (`colorWithRed:…/255.0 …alpha:1`), and set the WKWebView's
   `underPageBackgroundColor` guarded `if (@available(iOS 15.0, *))`.
3. Unset → keep the existing adaptive `systemBackgroundColor` (no regression).

iOS is full-screen / no live resize, so the payoff there is the launch /
pre-render fill and brand customization — note this in the comment too.

## Edge cases

- Empty / non-`#` / malformed hex → ignored, platform default kept.
- macOS transparent or vibrancy window → ignored (clear/material wins).
- Pre-macOS-12 / pre-iOS-15 → `underPageBackgroundColor` skipped; the
  window/view background still applies (the `@available` guard degrades
  cleanly).

## Docs + demo

- `runtime/window.ts`: update the `backgroundColor` docstring — now wired on
  macOS + iOS (opaque windows; transparent/vibrancy unaffected); keep the
  Windows-resize-flash vs. macOS-customization framing accurate.
- `docs/api-reference.md`: if the window-options section lists `backgroundColor`,
  note it's now macOS/iOS/Windows.
- hello-world (committed): add `backgroundColor: "#1e1e1e"` to one New Window
  demo so the window background is visibly the color (and, on Windows, the
  resize gap).

## Testing

- macOS build + ios-simulator build green; `bun run check` clean (doc-only TS
  change).
- Visual (user): a window created with `backgroundColor: "#1e1e1e"` shows a
  dark backing before/around content (most visible mid-resize on Windows;
  on macOS the window background itself is the color); a `transparent` or
  `vibrancy` window is unaffected.

## Out of scope

Runtime `setBackgroundColor` after creation; named/`rgb()`/8-digit-alpha color
forms; changing the page's own background (that's app CSS).
