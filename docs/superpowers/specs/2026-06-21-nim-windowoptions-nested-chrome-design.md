# Nim `WindowOptions` Nested Chrome — Design

**Date:** 2026-06-21
**Branch:** `feat/nim-native` (unmerged)
**Status:** Approved (design); spec under review

## Goal

Make the Nim `WindowOptions` author-facing shape match the already-nested
TS `WindowOptions` and the JSON wire, for the three chrome accessories:
`sidebar`, `inspector`, and `toolbar`. Today the Nim struct is the only flat
surface in the system; nesting it removes the divergence and lets a Nim app
author chrome the same way a TS app does.

## Background — the divergence

| Surface | Shape today |
|---|---|
| TS/JS `WindowOptions` authoring (`runtime/window.ts:227-232`) | **nested** — `sidebar?: SidebarOptions`, `inspector?: InspectorOptions`, `toolbar?: ToolbarOptions` |
| JSON wire (TS → native, and the `zapp.config.ts` window block) | **nested** for sidebar/inspector (`a{"sidebar"}`, `a{"inspector"}`); **`toolbarJson` string** for the toolbar |
| **Nim `WindowOptions` authoring struct (`native/nim/window.nim:79-105`)** | **flat** — `sidebarUrl`, `sidebarWidth`, `inspectorUrl`, …, `toolbarJson` |

`windowOptsApplyJson` (`window.nim:355-377`) already reads the nested
`sidebar`/`inspector` JSON objects and *flattens* them into the flat Nim
fields. So the flat shape exists only inside the Nim struct, and
`windowOptsApplyJson` is the (now-removable) flatten step.

The toolbar wire is intentionally asymmetric: at window-create, TS runs
`normalizeToolbar(opts.toolbar, …)` and sets `normalized.toolbarJson = json`
(`window.ts:1120-1121`) — a pre-serialized string, the exact blob the native
NSToolbar parser (`zapp_toolbar_parse_items`) and runtime `setItems` consume.
That asymmetry stays; it is an internal native detail, not an authoring concern.

## Scope

**In scope (Nim-side only):**
- `native/nim/window.nim` — new nested types, `WindowOptions` fields, the
  `wopts_*` accessor bodies, `windowOptsApplyJson`, and two new helpers
  (`serializeToolbar`, `parseToolbarJson`).
- `kitchen-sink/zapp/app.nim` — migrate the window construction to the nested
  shape.
- `native/nim/tests/windowmanager_test.nim` — update + extend.

**Out of scope (untouched):**
- `native/platform/darwin/window.m` and all `wopts_*` C-ABI **signatures** —
  unchanged. Only the Nim bodies change.
- The TS `WindowOptions` API (`runtime/window.ts`) — already nested.
- The JSON wire — `sidebar`/`inspector` stay nested objects; the toolbar stays
  a `toolbarJson` string. No CLI change.

## Architecture

### New Nim types (`window.nim`)

Field names align to the TS/JSON keys so all three surfaces read identically
(notably `resizable`, not the old `canResize`).

```nim
type
  MenuItemOpt* = object                    # mirrors TS ZappMenuItem
    id*, label*, icon*: string
    checked*: bool

  ToolbarItemOpt* = object                 # mirrors TS ToolbarItemDef — DATA fields only
    id*, `type`*, pane*, label*, icon*: string   # type "" ⇒ native treats as "button"
    enabled*: bool = true
    indicator*: bool
    menu*: seq[MenuItemOpt]

  ToolbarOptions* = object
    style*: string                         # "" ⇒ "unified"
    items*: seq[ToolbarItemOpt]

  SidebarOptions* = object
    url*, material*, backgroundColor*, presentation*: string
    width*: int32 = 260
    minWidth*: int32 = 180
    maxWidth*: int32 = 400
    collapsible*: bool = true
    collapsed*: bool
    resizable*: bool = true
    numericId*: int32 = -1

  InspectorOptions* = object               # same shape; width default 280
    url*, material*, backgroundColor*: string
    width*: int32 = 280
    minWidth*: int32 = 180
    maxWidth*: int32 = 400
    collapsible*: bool = true
    collapsed*: bool
    resizable*: bool = true
    numericId*: int32 = -1

  WindowOptions* = ref object
    ...                                     # title/url/width/... unchanged
    sidebar*: SidebarOptions
    inspector*: InspectorOptions
    toolbar*: ToolbarOptions
    toolbarJsonCache*: string               # derived; see "toolbar accessor" below
```

`ToolbarItemOpt` carries only the fields that **serialize** — there is no
`action` closure (a Nim app receives toolbar clicks via the existing
`TOOLBAR_CLICKED`/window-action event path, exactly as the wire does; closures
don't cross the C boundary).

### "Unset" semantics — unchanged sentinel

Sub-objects are always present and default-constructed. The native
short-circuits are preserved verbatim:
- `sidebar.url == ""` ⇒ sidebar never built (was `sidebarUrl == ""`).
- `inspector.url == ""` ⇒ inspector never built.
- `toolbar.items.len == 0` ⇒ `wopts_toolbar_json` returns `""` ⇒
  `darwin_toolbar_attach` is skipped (was `toolbarJson == ""`).

No `Option[T]`, no `ref`/nil. Object field defaults (width 260/280, collapsible
true, resizable true, …) carry over exactly as the old flat defaults did.

### Field-name mapping (flat → nested)

| Old flat field | New nested field |
|---|---|
| `sidebarUrl` / `sidebarMaterial` / `sidebarBackgroundColor` / `sidebarPresentation` | `sidebar.url` / `.material` / `.backgroundColor` / `.presentation` |
| `sidebarWidth` / `sidebarMinWidth` / `sidebarMaxWidth` | `sidebar.width` / `.minWidth` / `.maxWidth` |
| `sidebarCollapsible` / `sidebarCollapsed` | `sidebar.collapsible` / `.collapsed` |
| `sidebarCanResize` | `sidebar.resizable` (renamed to match TS/JSON) |
| `sidebarNumericId` | `sidebar.numericId` |
| `inspector*` (same set) | `inspector.*` |
| `toolbarJson` | `toolbar` (`ToolbarOptions`) + derived `toolbarJsonCache` |

### C-ABI accessors — `window.m` untouched

Every `wopts_sidebar_*` / `wopts_inspector_*` keeps its exact signature; the
body changes only its field path, e.g.:

```nim
proc wopts_sidebar_url(p: pointer): cstring {.exportc, cdecl.} = opt(p).sidebar.url.cstring
proc wopts_sidebar_can_resize(p: pointer): bool {.exportc, cdecl.} = opt(p).sidebar.resizable
```

(The accessor *name* `wopts_sidebar_can_resize` stays — window.m calls it — even
though the Nim field is now `resizable`.)

**Toolbar accessor (the one subtlety).** `wopts_toolbar_json` must return a
cstring whose buffer stays alive for window.m's synchronous read (BOUNDARY
RULE 1: the returned pointer borrows a GC-owned buffer on the GC_ref'd ref). A
freshly-serialized temporary would dangle. So the accessor serializes into the
ref's own `toolbarJsonCache` field and returns that:

```nim
proc wopts_toolbar_json(p: pointer): cstring {.exportc, cdecl.} =
  let o = opt(p)
  o.toolbarJsonCache = (if o.toolbar.items.len == 0: "" else: serializeToolbar(o.toolbar))
  o.toolbarJsonCache.cstring
```

`toolbarJsonCache` is a derived buffer, not an author-facing field —
`toolbar: ToolbarOptions` remains the single source of truth.

### `serializeToolbar` / `parseToolbarJson` helpers

`serializeToolbar(t: ToolbarOptions): string` emits the exact JSON schema the
native toolbar parser consumes and that TS's `normalizeToolbar` produces:

```json
{"style":"unified","items":[
  {"id":"…","type":"button","pane":"…","label":"…","icon":"…",
   "enabled":true,"indicator":false,
   "menu":[{"id":"…","label":"…","icon":"…","checked":false}]}]}
```

(omit empty optional keys to match the wire as closely as the existing TS output
— the impl plan pins the exact key set against `toolbar.m`'s parser and the TS
`normalizeToolbar` output.)

`parseToolbarJson(s: string): ToolbarOptions` is the inverse, used by
`windowOptsApplyJson` when a window arrives over the wire carrying a
`toolbarJson` string. This keeps `o.toolbar` the single source even for
config/TS-driven windows.

### `windowOptsApplyJson`

- `sidebar`/`inspector`: same nested JSON read, now assigning into
  `o.sidebar.*` / `o.inspector.*` (the flatten step is deleted).
- `toolbar`: replace `if jHasStr(a, "toolbarJson"): o.toolbarJson = …` with
  `if jHasStr(a, "toolbarJson"): o.toolbar = parseToolbarJson(jStr(a, "toolbarJson"))`.

## Data flow (after the change)

- **Nim app author:** `WindowOptions(sidebar: SidebarOptions(url: "#side", width: 240),
  toolbar: ToolbarOptions(items: @[...]))` → `wopts_*` read nested →
  `wopts_toolbar_json` serializes `toolbar` → native attaches.
- **Config / TS-driven (wire):** nested `sidebar`/`inspector` + `toolbarJson`
  string → `windowOptsApplyJson` writes `o.sidebar`/`o.inspector` and
  `parseToolbarJson` → `o.toolbar` → same accessors as above.

Both paths converge on the nested `WindowOptions`; the native side sees exactly
the byte-strings and scalars it sees today.

## Testing

- **Unit (`windowmanager_test.nim`, Nim test harness):**
  - `serializeToolbar` round-trips: a known `ToolbarOptions` → JSON contains the
    expected keys; `parseToolbarJson(serializeToolbar(t)) == t` for a
    representative item set (button, menu w/ checked, toggleSidebar,
    trackingSeparator w/ pane).
  - Wire round-trip: a representative `toolbarJson` string (matching TS
    `normalizeToolbar` output) → `parseToolbarJson` → `serializeToolbar`
    produces an equivalent native-consumable string.
  - Accessor reads: construct a `WindowOptions` with nested chrome, call the
    `wopts_*` accessors via the existing harness, assert the values + defaults
    (e.g. unspecified `sidebar.width == 260`, `inspector.width == 280`).
  - `windowOptsApplyJson` with nested sidebar/inspector + a `toolbarJson` string
    populates `o.sidebar`/`o.inspector`/`o.toolbar` correctly.
- **Build gates:** Nim macOS build (`[zapp] build complete:` as the last line,
  fresh binary mtime); iOS-sim build (the `wopts_*` accessors compile into the
  iOS binary too); `bun test cli/src` (no CLI change, but keep it green).
- **Human visual smoke (gate):** kitchen-sink window still renders the sidebar
  (overlay), the inspector, and the toolbar with the same items/positions as
  before — proving the nested authoring path produces identical native chrome.

## Risks / notes

- The serialize↔parse round-trip is the one correctness-sensitive piece; the
  unit round-trip test + the human smoke cover it. The impl plan pins the JSON
  key set against `toolbar.m`'s parser and TS `normalizeToolbar`.
- `toolbarJsonCache` is the only non-author-facing addition; documented inline
  as a C-boundary buffer.
- This is a breaking change for Nim app authors, but kitchen-sink is the only
  consumer and the branch is unmerged (no external users).
