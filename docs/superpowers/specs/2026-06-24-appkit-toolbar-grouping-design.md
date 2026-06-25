# AppKit Toolbar Grouping (NSToolbarItemGroup) — Design

**Date:** 2026-06-24
**Branch:** `feat/nim-native` (unmerged)
**Status:** Design approved; ready for implementation plan.

## Context

Deferred sibling of the W2 toolbar-affordances cycle (which shipped the per-item
styling trio and explicitly left grouping out). `NSToolbarItemGroup` has **two distinct
shapes**, both delivered here:

1. **Segmented control** — the convenience-constructor flavor: one unified control with
   N segments (Finder view-switcher / grouped action set). Carries `selectionMode`
   (selectOne / selectAny / momentary) and `selectedIndex`.
2. **Plain item grouping** — the `subitems`-property flavor: a cluster of full toolbar
   items that travel together and can collapse to an overflow menu when space is tight.
   No selection state.

`selectionMode` and `selectedIndex` **only apply to flavor 1** (the system control
representation). Per the SDK, a group may not contain other groups.

**Consistency principle (drove the API).** All "menu-like" surfaces in Zapp share one
click primitive: `action: () => void`, keyed by `id`, no args — the item "knows itself"
via its closure (`MenuItemDef` for Menu/ContextMenu/Tray/toolbar pull-downs, and
`ToolbarItemDef`). Grouping keeps that primitive: `group` subitems are literally
`ToolbarItemDef`s; `segmented` segments expose the same `action: () => void`. The only
divergence is genuinely group-specific selection state, delivered via a dedicated event
(below). A broader unification of the callback/event surface (public `MENU_CLICKED`
parity + an optional context payload to closures) is tracked separately as a follow-up
and intentionally NOT pre-decided here.

### Confirmed SDK APIs (`AppKit.framework/Headers/NSToolbarItemGroup.h`, macOS 10.15+)

| API | Notes |
| --- | --- |
| `+groupWithItemIdentifier:titles:selectionMode:labels:target:action:` | segmented control from titles |
| `+groupWithItemIdentifier:images:selectionMode:labels:target:action:` | segmented control from images |
| `subitems` (`NSArray<NSToolbarItem*>`) | plain grouping (manual items) |
| `selectionMode` (`SelectOne=0` / `SelectAny=1` / `Momentary=2`) | segmented only |
| `controlRepresentation` (`Automatic` / `Expanded` / `Collapsed`) | both flavors |
| `selectedIndex` (-1 = none), `setSelected:atIndex:`, `isSelectedAtIndex:` | segmented only |

`NSToolbarItemGroup` is macOS 10.15 — **older than the toolbar's existing assumed floor**
(the toolbar already gates `bordered`/`NSMenuToolbarItem` at 10.15). So no macOS-26 gate
and **no fallback complexity** (unlike the W2 trio).

## Goals

- Two new toolbar item kinds, TS↔Nim parity, serialized to one wire shape parsed in
  `toolbar.m`:
  - `type: "segmented"` — segments + `selectionMode` + `selected` + `controlRepresentation`.
  - `type: "group"` — `items: ToolbarItemDef[]` + `controlRepresentation`.
- Keep the `action: () => void` click primitive across segments and subitems.
- Stateful selection (selectOne/selectAny): a public, pane/worker-subscribable
  `TOOLBAR_GROUP_SELECTED` event `{id, index, selected}` (`selected` = the index's new
  state — always `true` for selectOne; the toggle's result for selectAny), an initial
  `selected`, and live `win.toolbar.updateItem(id, { selected })`.
- Kitchen-sink showcase + docs.

## Non-Goals

- Changing the existing `action: () => void` signature or adding a context payload to
  closures, or adding public `MENU_CLICKED` events — that's the cross-cutting follow-up
  (separate task), applied uniformly later.
- Nested groups (SDK-disallowed).
- iOS toolbar grouping (the toolbar pipeline is macOS-only; the new keys travel in the
  toolbar JSON but are parsed only in darwin `toolbar.m` — no iOS surface, no new C-ABI).
- `accessibilityLabel`/customization-palette niceties beyond what the convenience ctor
  gives for free.

## API (approach A — two explicit item types)

### TS — `runtime/window.ts`

`ToolbarItemDef.type` gains `"segmented"` and `"group"`. New fields (only meaningful on
those types):

```ts
/** A segment of a "segmented" group. A menu-like item: same action primitive. */
export interface ToolbarSegmentDef {
  /** Optional id for click routing / updateItem targeting. */
  id?: string;
  /** Segment label OR icon (convenience ctor takes titles or images, not both kinds
   *  mixed across the group). */
  label?: string;
  icon?: string;       // "sf:<symbol>" | path | data URL
  enabled?: boolean;   // default true
  /** Fires when this segment is pressed (momentary) or becomes selected
   *  (selectOne/selectAny). Same primitive as MenuItemDef/ToolbarItemDef. */
  action?: () => void;
}

// On ToolbarItemDef (only for the new types):
/** "segmented": NSToolbarItemGroup convenience control. */
segments?: ToolbarSegmentDef[];
/** "segmented": how selection is handled. Default "momentary". */
selectionMode?: "one" | "any" | "momentary";
/** "segmented": initial selection — index (one) or indices (any). Ignored for momentary. */
selected?: number | number[];
/** "group": the clustered full items. */
items?: ToolbarItemDef[];
/** "segmented" + "group": how the control collapses. Default "automatic". */
controlRepresentation?: "automatic" | "expanded" | "collapsed";
```

`ToolbarItemPatch` gains `selected?: number | number[]` (live selection) and
`controlRepresentation?`. (Per-segment enabled/label patching is out of scope v1 —
rebuild the item set to change segments; documented.)

`normalizeToolbar` validates: `"segmented"` requires non-empty `segments` (each with
`label` xor `icon`); `"group"` requires non-empty `items`; `id` required on both;
`segments`/`items` are type-appropriate (error otherwise). Segment `action`s are stripped
and registered like menu/toolbar actions (keyed by group id + segment index/id).

### Nim — `native/nim/window.nim` (parity)

```nim
ToolbarGroupSelectionMode* {.pure.} = enum
  Momentary = "momentary", One = "one", Any = "any"
ToolbarControlRepresentation* {.pure.} = enum
  Automatic = "automatic", Expanded = "expanded", Collapsed = "collapsed"

ToolbarSegmentOpt* = object
  id*, label*, icon*: string
  enabled*: bool = true

# ToolbarItemOpt gains (DATA only — no action closures, mirroring existing convention):
segments*: seq[ToolbarSegmentOpt]
selectionMode*: ToolbarGroupSelectionMode      # default Momentary
selected*: seq[int]                            # 0/1+ indices; empty = none
controlRepresentation*: ToolbarControlRepresentation  # default Automatic
items*: seq[ToolbarItemOpt]                    # "group" subitems (recursive, ONE level)
```

`serializeToolbar`/`parseToolbarJson` emit/parse the new keys with omit-when-default
(matching the existing toolbar round-trip invariant). `items` recursion is one level
(SDK disallows nested groups; reject a group inside `items`).

### Wire JSON

```json
{ "type": "segmented", "id": "view",
  "selectionMode": "one", "selected": [1], "controlRepresentation": "automatic",
  "segments": [ {"id":"icon","icon":"sf:square.grid.2x2"},
                {"id":"list","icon":"sf:list.bullet"} ] }

{ "type": "group", "id": "nav", "controlRepresentation": "collapsed",
  "items": [ {"type":"button","id":"back","icon":"sf:chevron.left"},
             {"type":"button","id":"fwd","icon":"sf:chevron.right"} ] }
```

`selected` is always an array on the wire (`[]` = none, `[n]` = one, `[a,b]` = any) for a
single Nim type; TS normalizes `number` → `[number]`.

## Click / selection semantics

- **`group` subitems** — each is a normal toolbar button: its own `action` + the existing
  public `TOOLBAR_CLICKED`. Zero new plumbing.
- **`segmented` momentary** — pressing segment *N* runs `segments[N].action()` (creator
  closure, via the existing click broadcast). No persistent selection.
- **`segmented` selectOne / selectAny** — selecting segment *N*:
  1. runs `segments[N].action()` (creator closure), and
  2. emits a new public **`TOOLBAR_GROUP_SELECTED` `{ windowId, id, index, selected }`**
     (group id + the changed index + that index's new state — `true` always for
     selectOne; the toggle result for selectAny), subscribable via `win.on(...)` by any
     pane or worker — parity with `TOOLBAR_CLICKED`. (Momentary emits NO
     `TOOLBAR_GROUP_SELECTED` — it has no selection; the per-segment `action` is its only
     signal.)
- Initial selection: `selected`. Live: `win.toolbar.updateItem(id, { selected })`
  (→ native `selectedIndex` / `setSelected:atIndex:`). Current selection is tracked from
  the event (fire-and-forget model, same as sidebar collapsed-state) — no synchronous
  getter in v1.

## Native (`native/platform/darwin/toolbar.m`)

- `zapp_toolbar_parse_items` + the builder grow two arms:
  - `"segmented"` → `+groupWithItemIdentifier:titles:|images:selectionMode:labels:target:action:`
    (titles when segments carry labels, images when they carry icons via `zapp_resolve_icon`),
    set `controlRepresentation`, set initial `selectedIndex`, and wire the group
    target/action to a new `zapp_toolbar_emit_group_select(host_id, group_id, index, selected)`.
  - `"group"` → `[[NSToolbarItemGroup alloc] initWithItemIdentifier:]`, build each nested
    item via the existing button builder, assign `.subitems`, set `controlRepresentation`.
- `zapp_toolbar_emit_group_select` mirrors `zapp_toolbar_emit_click`: broadcast
  `window:toolbar-group-selected` `{windowId,id,index,selected}` to all webviews + workers.
- `darwin_toolbar_update_item`: when the merged def is a segmented group and the patch
  carries `selected`, apply `selectedIndex`/`setSelected:atIndex:` on the live group;
  `controlRepresentation` patch likewise.
- Stored def already carries the new keys (the parser stores whole defs), so the builder
  reads them directly. Gating: wrap NSToolbarItemGroup use in `if (@available(macOS 10.15, *))`
  (the toolbar's existing floor); below that the group item is dropped (warn) — effectively
  never hit on supported macOS.

## Runtime wiring (`runtime/window.ts`)

- New `WindowEvent.TOOLBAR_GROUP_SELECTED` (+ event-name mapping + Nim `coretypes`
  event id + bootstrap dispatch, mirroring `TOOLBAR_CLICKED`).
- `normalizeToolbar` registers segment actions in the toolbar action map keyed by
  `windowId:groupId:index` (or `:segmentId`); the `TOOLBAR_GROUP_SELECTED` handler runs
  the matching segment action AND re-emits the public event for `win.on` subscribers.
- `updateItem` accepts `selected`/`controlRepresentation` and routes them on the wire.

## Showcase (kitchen-sink)

Toolbar section / shell toolbar:
- a `selectOne` **view-switcher** segmented control (icon / list / grid) whose
  `TOOLBAR_GROUP_SELECTED` updates the section result + inspector state;
- a `momentary` grouped action set (e.g. bold / italic / underline) demonstrating
  per-segment `action`;
- a `type: "group"` cluster (e.g. back / forward) with `controlRepresentation` to show
  overflow-collapse when the window narrows.

## Testing & gates

- **TDD (TS, bun):** `normalizeToolbar` emits both types' wire shapes + validation
  (segmented requires segments, group requires items, id required, `number`→`[number]`);
  `normalizeToolbarPatch` for `selected`/`controlRepresentation`.
- **TDD (Nim):** `serializeToolbar`/`parseToolbarJson` round-trip both types incl. enums
  + `selected` array + nested `items`.
- **Build matrix:** `bun test runtime cli/src`, macOS `[zapp] build complete:`, iOS-sim
  (no regression — toolbar is macOS-only).
- **Human visual smoke:** segmented view-switcher selects + emits; momentary group fires
  per-segment; plain group clusters + collapses; live `updateItem({selected})`.

## Plan shape

1. **T1 — segmented (the headline):** TS `type:"segmented"` + `ToolbarSegmentDef` +
   normalize (TDD); Nim parity + serialize/parse (TDD); `TOOLBAR_GROUP_SELECTED` event
   across the stack; `toolbar.m` segmented arm + `zapp_toolbar_emit_group_select` +
   `updateItem({selected})`. End-to-end selectOne/any/momentary.
2. **T2 — plain group:** TS `type:"group"` + `items` (recursive, one level) + normalize;
   Nim parity; `toolbar.m` subitems arm + `controlRepresentation`.
3. **T3 — showcase + docs + gates:** kitchen-sink demos, api-reference + native-ui-strategy,
   full build matrix, human visual smoke.

No risk gate (10.15 APIs, well-understood; the W2 risk was the unproven macOS-26 surface).

## Follow-ups (not in scope)

- Menu-like callback/event unification: public `MENU_CLICKED` parity + optional context
  payload to action closures, applied across `MenuItemDef`/`ToolbarItemDef`/segments
  (tracked task). Segments inherit it for free once it lands.
- Per-segment live patching (enabled/label) without a full rebuild.
- Synchronous "current selection" getter (today selection is event-tracked).
