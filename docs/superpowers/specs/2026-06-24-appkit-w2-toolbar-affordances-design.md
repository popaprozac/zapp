# AppKit W2 — Toolbar Affordances (macOS new design)

**Date:** 2026-06-24
**Branch:** `feat/nim-native` (unmerged)
**Status:** Design approved; ready for implementation plan.

## Context

Second sub-cycle of the AppKit new-design ("Build an AppKit app with the new design",
WWDC26 / macOS 26 Tahoe) adoption. W1 (native glass by default) needed no code; W3
(content `backgroundExtension`) shipped. W2 adds **per-item toolbar styling affordances**
that recover the richer "Liquid Glass" toolbar look natively, surfaced through the
existing `ToolbarHandle` / `ToolbarItemDef` API.

All four candidate affordances were confirmed in `MacOSX26.4.sdk`
(`AppKit.framework/Headers/NSToolbarItem.h`, `NSItemBadge.h`). This cycle ships the
**per-item styling trio**; `NSToolbarItemGroup` grouping is **deferred** to its own later
cycle (it is structurally different — an item that holds subitems with selection
modes / segmented representation — a bigger model change).

### Confirmed SDK APIs (the trio)

| Affordance | API | Availability |
| --- | --- | --- |
| Prominent style + tint | `item.style = NSToolbarItemStyleProminent` + `item.backgroundTintColor` (NSColor) | macOS 26.0 |
| Badge | `item.badge = NSItemBadge` via `+badgeWithCount:` / `+badgeWithText:` / `+indicatorBadge` | macOS 26.0 |
| Non-bordered | `item.bordered = NO` (`isBordered`) | macOS 10.15 (all) |

`NSToolbarItemStyle` is `{ Plain, Prominent }`. `backgroundTintColor` applies **only**
when the item's style is prominent; when prominent with no tint set, AppKit uses the
app/system accent color.

## Goals

- Add `style`, `tintColor`, `badge`, `bordered` to a toolbar item — at create time and
  via `win.toolbar.updateItem` (live-updatable).
- Keep the TS (`ToolbarItemDef`) and Nim (`ToolbarItemOpt`) surfaces in parity, both
  serializing to the same wire JSON parsed once in `toolbar.m`.
- Graceful, silent fallback on < macOS 26 (item renders plain, no badge); `bordered`
  works on all versions.
- Demonstrate the trio in the kitchen-sink Toolbar section, including a **live** badge.

## Non-Goals

- `NSToolbarItemGroup` grouping / segmented items / selection modes (deferred — its own
  cycle).
- iOS toolbar affordances. The toolbar is macOS-only today (`ToolbarHandle` no-ops
  off-macOS); W2 adds **no** new C-ABI symbols, router arms, or iOS stubs.
- A unified color parser. `tintColor` takes a hex string now; the broader `std/color`
  effort (follow-up #685, which targets the Nim window/sidebar/inspector
  `backgroundColor` path) is independent and may later unify this.

## API (recommended: flat additive fields, string-union `style`)

Mirrors the existing flat convention on `ToolbarItemDef` (`type`, `enabled`, `indicator`).

### TS — `runtime/window.ts`

`ToolbarItemDef` gains:

```ts
/** macOS 26+. "prominent" tints the item background (accent or `tintColor`),
 *  the new-design highlighted-action look (e.g. a primary "Done"). Default
 *  "plain". No-op < macOS 26. */
style?: "plain" | "prominent";
/** macOS 26+. Hex color (e.g. "#aa3bff") tinting a prominent item's
 *  background. Ignored unless `style` is "prominent"; omit → system accent.
 *  No-op < macOS 26. */
tintColor?: string;
/** macOS 26+. A badge on the item: a localized count, short text, or a plain
 *  dot indicator. No-op < macOS 26. */
badge?: { count: number } | { text: string } | { dot: true };
/** Whether the item draws its standard bordered background. Default true;
 *  false → flat (e.g. label-like / image-only items). All macOS versions. */
bordered?: boolean;
```

`ToolbarItemPatch` gains the same four, plus `badge?: … | null` where **`null` clears**
the badge (omitted = unchanged, matching the existing patch semantics).

`normalizeToolbar` / `normalizeToolbarPatch` pass the fields through to the wire JSON,
converting the `badge` union to the tagged wire form below. `style`/`bordered`
default-elision: only emit when set (so the wire stays minimal and native defaults
apply), consistent with how the toolbar JSON is already built.

### Nim — `native/nim/window.nim`

`ToolbarItemOpt` gains parity fields (Nim is statically typed, so the badge union
becomes a tagged object):

```nim
ToolbarBadgeKind* {.pure.} = enum
  None = "none", Count = "count", Text = "text", Dot = "dot"

ToolbarBadge* = object
  kind*: ToolbarBadgeKind          ## None ⇒ no badge / clear
  count*: int
  text*: string

# added to ToolbarItemOpt:
style*: ToolbarItemStyle           ## new enum {Plain="plain", Prominent="prominent"}; default Plain
tintColor*: string                 ## hex; emitted only when style==Prominent
badge*: ToolbarBadge               ## kind None ⇒ omitted
bordered*: bool = true
```

`serializeToolbar` emits the new keys (matching `toolbar.m`'s parse); `deserializeToolbar`
parses them back (for windows that arrive carrying a pre-serialized `toolbarJson`).

### Wire JSON (parsed once in `toolbar.m`)

Per item, additive keys (all optional; absence ⇒ native default):

```json
{
  "id": "compose",
  "style": "prominent",
  "tintColor": "#aa3bff",
  "badge": { "kind": "count", "count": 3 },
  "bordered": false
}
```

`badge.kind` ∈ `"count" | "text" | "dot" | "none"`. `"count"` carries `count`; `"text"`
carries `text`; `"dot"` and `"none"` carry nothing. In a patch, `"none"` (or `badge: null`
on the TS side → `{"kind":"none"}` on the wire) clears the badge.

## Native (`native/platform/darwin/toolbar.m`)

Two existing sites apply the fields; no new exported symbols.

1. **Item builder** (`toolbar:itemForItemIdentifier:`, ~line 140–244) — after constructing
   the `NSToolbarItem` / `NSMenuToolbarItem`, read the stored item def and apply:

   ```objc
   item.bordered = borderedFromDef;          // ungated; default YES
   if (@available(macOS 26.0, *)) {
       item.style = prominent ? NSToolbarItemStyleProminent : NSToolbarItemStylePlain;
       item.backgroundTintColor = (prominent && tintHex) ? zapp_toolbar_color(tintHex) : nil;
       item.badge = zapp_toolbar_badge(badgeKind, badgeCount, badgeText); // nil ⇒ no badge
   }
   ```

2. **`updateItem` mutate-path** (~line 430–530) — mutate the same properties on the live
   item for patched fields (guard the macOS-26 trio behind `@available`; mutate `bordered`
   ungated). Badge `kind:"none"` / patch `badge:null` → `item.badge = nil`.

Helpers (static, in `toolbar.m`):
- `zapp_toolbar_color(NSString* hex) → NSColor*` — hex (`#RGB`/`#RRGGBB`/`#RRGGBBAA`)
  to NSColor; reuse the existing `zapp_parse_hex_color` logic from `window.m` (port/share
  a small parser; do not introduce a cross-file dependency that breaks the darwin-only
  build).
- `zapp_toolbar_badge(kind, count, text) → NSItemBadge*` (macOS 26) — maps to
  `+badgeWithCount:` / `+badgeWithText:` / `+indicatorBadge`; returns nil for `none`.

The item def must be retained for the builder to read (the controller already stores the
button defs used to build items; the trio fields ride along in that stored def).

## Fallback & platforms

- **< macOS 26:** `style`, `tintColor`, `badge` are inside `if (@available(macOS 26.0,*))`
  → silently skipped; the item renders as a normal bordered button. `bordered` applies on
  all versions. No logging on the hot path (matches existing toolbar behavior).
- **iOS / non-macOS:** unchanged. The toolbar pipeline is macOS-only; the new keys travel
  in the toolbar JSON but are never parsed off-macOS. No iOS stubs, no parity-lint surface
  (no new `darwin_*` symbols referenced from shared `.zc`/`.nim`).

## Showcase (kitchen-sink)

Toolbar section (`kitchen-sink/src/shell/toolbar-def.ts` + `src/sections/toolbar.ts`):
- A **prominent** primary action with a `tintColor` (the accent-tinted "wow" item).
- A **borderless** item (`bordered: false`) next to a normal one for contrast.
- A **live badge**: a button whose badge count the section increments on click via
  `win.toolbar.updateItem("…", { badge: { count: n } })`, and a "clear" that sends
  `{ badge: null }` — demonstrating dynamic badges (the notification-count use case).
- Section inspector (optional) can show the current style/badge state.

Keep the existing toolbar demo behavior intact; add the trio to the shell toolbar / the
section's controls.

## Testing & gates

- **TDD (TS, bun):** extend the existing toolbar normalize tests — `normalizeToolbar`
  emits `style`/`tintColor`/`bordered`/tagged-`badge` correctly (incl. default elision);
  `normalizeToolbarPatch` emits them and maps `badge: null` → `{"kind":"none"}`.
- **TDD (Nim):** `serializeToolbar` emits the new keys; `deserializeToolbar` round-trips
  them (badge kind/count/text; style enum; bordered).
- **Build matrix:** `bun test runtime cli/src`, macOS `[zapp] build complete:` + fresh
  binary, iOS-sim build (no regression — toolbar is macOS-only but the shared build must
  stay green).
- **T1 risk-gate (human visual):** before the full build-out, a minimal check that
  `style=prominent` + a `badge` actually render on our standard `NSToolbarItem`s (not just
  view-backed items). GO → proceed; NO-GO → revisit (e.g. items may need a custom view).
- **Final human visual smoke:** prominent tint, borderless contrast, live badge
  increment/clear; verify graceful plain rendering is plausible (we're on macOS 26/27, so
  < 26 fallback is reasoned, not run).

## Plan shape

1. **T1 (RISK GATE, human visual)** — prove `style=prominent` + `badge` render on a
   standard `NSToolbarItem` (hardcode on one kitchen-sink item, smoke, then revert the
   hardcode).
2. **T2** — TS `ToolbarItemDef`/`ToolbarItemPatch` fields + `normalizeToolbar`/
   `normalizeToolbarPatch` (TDD).
3. **T3** — Nim `ToolbarItemStyle`/`ToolbarBadge`/`ToolbarItemOpt` fields +
   `serializeToolbar`/`deserializeToolbar` (TDD).
4. **T4** — `toolbar.m` apply (builder + `updateItem`) + color/badge helpers.
5. **T5** — kitchen-sink showcase + docs (api-reference toolbar section +
   native-ui-strategy) + build matrix + final human visual smoke.

## Follow-ups (not in scope)

- `NSToolbarItemGroup` grouping / segmented items (own cycle).
- `std/color` unification (#685) could later replace the hex-only `tintColor` parser.
- `toolbarStyle` as a window-level option (#647) and the toolbar placement model (#643)
  remain independent.
