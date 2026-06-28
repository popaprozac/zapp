# Toolbar Placement Model — Design

**Date:** 2026-06-27
**Branch:** `feat/nim-native` (UNMERGED)
**Status:** Approved (design); spec for `writing-plans` → subagent-driven execution
**Closes (API half):** #643 (evolve toolbar API toward a cross-platform placement model)

## Goal

Add a cross-platform `placement` to toolbar items so one `ToolbarItemDef` lays out
correctly on macOS today and maps cleanly to iOS navigation-bar slots in a later
cycle. **macOS-only this cycle** — the macOS toolbar must render identically to
today (no visual regression). The native iOS toolbar (`UINavigationItem`) is the
*next* cycle, built on the placement metadata this cycle ships.

## Background

Surveyed state (feat/nim-native):

- **macOS** `NSToolbar` is rich and shipped: buttons, segmented, groups, labels,
  pull-down menus, `trackingSeparator`, `toggleSidebar`/`toggleInspector`, plus
  macOS-26 prominent/tint/badge. API: `ToolbarItemDef` union (`runtime/window.ts`)
  → `normalizeToolbar` → Nim `ToolbarItemOpt` (`native/nim/window.nim`) →
  `darwin/toolbar.m`. Full TS↔Nim↔native parity.
- **iOS** `ios/toolbar.m` is 100% no-op stubs; the kitchen-sink fakes a top bar in
  HTML (`main-pane.ts`, `☰`/title/`⊟`) that calls `sidebar/inspector.toggle()`
  directly and never routes through `toolbar.setItems()`.
- **The gap (#643):** the API is **NSToolbar-shaped** — one flat ordered `items[]`
  positioned by `space`/`flexibleSpace`/`trackingSeparator`. iOS `UINavigationItem`
  is **slot-based** (`leading` / `title` / `trailing`, + a later bottom `UIToolbar`)
  and items cannot cross slots by ordering. A flat list cannot drive iOS; a
  placement model is the prerequisite.

The API is unreleased on this branch, so we change it cleanly — the kitchen-sink
and docs are the only consumers.

## Decisions (from brainstorming)

1. **Scope:** placement-model API *first* (this cycle); native iOS toolbar is a
   separate follow-on cycle.
2. **API shape:** per-item `placement` field on the existing flat `items[]` array
   (not a slot-keyed object). Preserves all existing machinery — `updateItem(id)`,
   dynamic add/remove, `trackingSeparator` as a positional item, groups.
3. **macOS honors placement:** macOS sorts items into leading/center/trailing and
   auto-inserts `flexibleSpace` between non-empty groups (one authoring model both
   platforms read).
4. **Slots this cycle:** `leading` / `center` / `trailing`. `bottom` (iOS bottom
   `UIToolbar`) is deferred — it is an additive, non-breaking enum value added when
   the iOS bottom bar is actually implemented.

## API

```ts
type ToolbarPlacement = "leading" | "center" | "trailing";
```

- `placement?: ToolbarPlacement` is added to **every** toolbar item def
  (`ToolbarButtonDef`, `ToolbarSegmentedDef`, `ToolbarGroupDef`,
  `ToolbarTrackingSepDef`, `ToolbarSystemDef`, `ToolbarLabelDef`). Default
  `"leading"`.
- **Not patchable via `updateItem`.** Placement is structural like `id`/`type` —
  moving an item between slots is a `setItems` operation. `ToolbarItemPatch` and
  `TOOLBAR_PATCH_KEYS` are unchanged.
- Within a slot, **array order is preserved**. `space`/`flexibleSpace` remain valid
  *inside* a slot as fixed/elastic escape hatches.
- Invalid `placement` values are rejected by `normalizeToolbar` (same validation
  path as other enum fields).

## macOS mapping (`darwin/toolbar.m`)

When building the `NSToolbar` identifier list, **stably sort** items into
`leading → center → trailing` (preserving within-group order), then **auto-insert
`NSToolbarFlexibleSpaceItemIdentifier` between non-empty groups**:

```
[leading items] | flexSpace | [center items] | flexSpace | [trailing items]
```

(flexSpace inserted only between two non-empty groups — the standard NSToolbar
centering idiom: two flexible spaces balance the center group.) `trackingSeparator`,
`toggleSidebar`/`toggleInspector`, segmented and group items all stay positional
**within** their group. `set_items` / `update_item` / `remove` are otherwise
unchanged — only the build-order step is new. The id→def registry and all existing
item construction are untouched.

## Components (native-first parity, single PR)

| Layer | File | Change |
|---|---|---|
| TS runtime | `runtime/window.ts` | `ToolbarPlacement` type; `placement?` on each item def (default `"leading"`); `normalizeToolbar` writes `placement` into each item's wire JSON; validation. |
| Nim | `native/nim/window.nim` | `ToolbarPlacement` enum (`Leading`/`Center`/`Trailing`); `placement` field on `ToolbarItemOpt` (default `Leading`); `serializeToolbar`/`parseToolbarJson` round-trip parity. |
| Native macOS | `native/platform/darwin/toolbar.m` | placement sort + auto-flexSpace bracketing in the identifier-list build. |
| Native iOS | `native/platform/ios/toolbar.m` | **unchanged stubs** — placement rides in the wire JSON, consumed by the future iOS toolbar cycle. |
| Kitchen-sink | `kitchen-sink/src/shell/toolbar-def.ts` | migrate `shellToolbar()` from manual `flexibleSpace` to `placement` (proves the model + is the macOS no-regression smoke). |
| Docs | `docs/api-reference.md` | document `placement`, the macOS slot mapping, the iOS-future note. |

### Kitchen-sink migration (target layout, visually identical to today)

- **leading:** `toggleSidebar`, `trackingSeparator(sidebar)`, `compose`, `inbox`
- **center:** `group:nav`, `segmented:view`, `segmented:fmt`
- **trailing:** `filter`, `label:status`, `trackingSeparator(inspector)`,
  `toggleInspector`

The two manual `flexibleSpace` items are removed (now auto-inserted between groups).

## Out of scope (next cycle / YAGNI)

- Native iOS `UINavigationItem` toolbar implementation.
- The `bottom` slot / iOS bottom `UIToolbar`.
- Any change to `trackingSeparator` semantics (stays a positional divider-tracker).

## Testing & gates

- **Nim unit test:** `placement` serialize → parse round-trip (Leading/Center/
  Trailing + default), in the existing toolbar Nim test file.
- **TS:** `normalizeToolbar` emits `placement` for each item incl. the default;
  `updateItem` does not accept `placement` (structural).
- **Gates:** `bun run check`; `bun test cli/src`; `bun run test:native`; iOS compile
  (`cd kitchen-sink && bun run build --platform ios` → `[zapp] build complete:`);
  macOS build (`cd kitchen-sink && bun run build` → `[zapp] build complete:`).
- **Human smoke (macOS, the risk gate):** the migrated kitchen-sink toolbar renders
  **identically** to today — leading group left, center group centered, trailing
  group right; dynamic updates (badge, enabled, label, menu, remove/re-add) still
  work; `trackingSeparator`s still track the sidebar/inspector dividers.
- **iOS smoke:** HTML stand-in unchanged, app launches, toolbar ops no-op (no crash).

## Risk

**macOS visual regression** is the only real risk — the layout build changes. The
migrated `shellToolbar()` already splits leading/trailing with `flexibleSpace`, so
the placement-based output should match pixel-for-pixel. The macOS human visual
smoke is the gate.

## Constraints

Branch `feat/nim-native` UNMERGED; commit trailer EXACTLY
`Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`; per-file `git add`; Bun;
native-first parity (C primitive → Nim → router → TS runtime → docs, same PR);
Nim faithful to the wire contract; NO iOS simulator interaction in-session
(build-only + human smoke); macOS is the parity reference (don't regress); docs
updated in the same PR.
