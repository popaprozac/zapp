# Custom icons in menu items — design

**Date:** 2026-06-05
**Branch:** `feat/menu-icons`
**Surfaced by:** user request (saw menu enrichment in the Wails discord). Realizes the captured `project_menu_item_icons` design. Sliders / custom-view menu items are a deliberately separate future feature (not this).

## Decisions (from brainstorming)

1. **Sources** — `icon: string` accepting three forms: `"sf:<name>"` (SF Symbol), a **file path** (relative-resolved like tray), and `"data:image/png;base64,…"` (dynamic, JS-produced). One string field, all JSON-serializable; no raw-bytes API (binary can't ride the JSON menu wire — the data-URL *is* the byte channel).
2. **Template** — smart per-source default: `sf:`→template (auto-tints to menu text + dark mode), file/data→full-color (WYSIWYG). Override with `iconTemplate?: boolean`. (Avoids the tray white-blob footgun.)
3. **Scope** — all three menu surfaces (app menu, context menu, tray menu) via a **shared `zapp_resolve_icon` helper**, since native has two item-builders (`menu.m` + `tray.m`).
4. **Platform** — macOS only (iOS menus are no-op stubs).

## API surface

Two optional fields on `MenuItemDef` (`runtime/menu.ts`) — automatically available to app menus, context menus, and tray menus, which all share the type:
```ts
export interface MenuItemDef {
  // existing: id?, label?, type?, enabled?, checked?, accelerator?, role?, action?, submenu?
  /** Icon: "sf:gear" (SF Symbol) | "build/logo.png" (file path) | "data:image/png;base64,…". macOS only. */
  icon?: string;
  /** Force template (monochrome, auto-tinted) on/off. Default: sf:→true, file/data→false. */
  iconTemplate?: boolean;
}
```
```ts
Menu.build([{ label: "File", submenu: [
  { label: "New",  icon: "sf:doc.badge.plus", accelerator: "CmdOrCtrl+N", action: onNew },
  { label: "Open Recent", icon: "sf:clock" },
]}]);
ContextMenu.show([{ label: "Copy", icon: "sf:doc.on.doc", action: onCopy }], { x, y });
tray.setMenu([{ label: "Dashboard", icon: "build/logo.png", action: open }]);
// dynamic:
const url = canvas.toDataURL("image/png");
tray.setMenu([{ label: "Status", icon: url }]);
```

## Icon resolution semantics

A shared native resolver `NSImage* zapp_resolve_icon(NSString* spec, CGFloat size, int templateMode)`:
- **Form dispatch:** `spec` starts with `"sf:"` → `imageWithSystemSymbolName:` (macOS 11+, the part after `sf:`); starts with `"data:"` → strip the `data:…;base64,` prefix, base64-decode, `NSImage initWithData:`; otherwise → treat as a **file path**, relative-resolve against cwd (dev) + bundle resources (packaged) like `tray.m apply_icon`, then `initWithContentsOfFile:`.
- **Template:** `templateMode` is tri-state — `-1` (auto) / `0` (off) / `1` (on). Auto resolves to `template = (spec hasPrefix "sf:")`. Set `img.template = …`.
- **Size:** `img.size = NSMakeSize(size, size)` — menu items pass ~**16** (menu-standard) so large PNGs don't inflate rows.
- **Failure:** return `nil` (the caller renders the item icon-less); log `[zapp] menu: could not load icon <spec>`. No "?" placeholder in menus (that's a tray-status-icon-only behavior).

## Native architecture

**Single builder, single insertion.** Investigation showed all three surfaces funnel through `menu.m`'s `add_menu_item`: app menus build there directly; context menus call `build_menu_from_json` (menu.m:305 in `darwin_menu_show_context_from_payload`); tray menus call `darwin_menu_build_from_items_json` (menu.m:565) which calls the same builder. So **wiring icons in `add_menu_item` covers app + context + tray with one change** — `tray.m` is NOT touched, and no separate `icon.m` is needed.

- **`zapp_resolve_icon`** — a `static NSImage* zapp_resolve_icon(NSString* spec, CGFloat size, int templateMode)` helper **in `native/platform/darwin/menu.m`** (one caller, so file-local; the tray status-bar icon could de-static + reuse it later). Form dispatch + template + size + nil-on-failure as in "Icon resolution" above. Relative-path resolve mirrors `tray.m apply_icon` (cwd + bundle resources).
- **`add_menu_item`** — after the existing `enabled`/`checked` wiring (menu.m ~line 219), read `def[@"icon"]`; if a non-empty string, `item.image = zapp_resolve_icon(icon, 16, templateModeFrom(def))`.
- **`templateModeFrom(def)`** — `static int`: `def[@"iconTemplate"]` present → `[v boolValue] ? 1 : 0`; else `-1` (auto = `[spec hasPrefix:@"sf:"]`).
- **No `cli/src/native.ts` / `build.zc` / iOS changes** — `menu.m` is already compiled (darwin); the helper is darwin-only + `.m`-internal (not referenced from `.zc`), so no parity/stub work. iOS menus stay no-op.
- The tray **status-bar** icon (`tray.m apply_icon`) is **unchanged** in v1 (distinct "?" placeholder + fixed 18px). Follow-up: de-static `zapp_resolve_icon` and have `apply_icon` reuse it to gain `sf:`/`data:` — out of scope here.

## TS chain

`icon`/`iconTemplate` added to `MenuItemDef`. The existing `stripActions` in `runtime/menu.ts`, `runtime/tray.ts`, and `runtime/context-menu.ts` deletes only `action` (and recurses `submenu`), keeping all other fields — so the two new fields pass through to the native JSON with **no serialization changes**. Native reads `def["icon"]` / `def["iconTemplate"]`. (Plan verifies each stripActions keeps unknown fields.)

## Verification

- `bun run check` 0; `bun run test:all` green; macOS `bun run build` → `[zapp] build complete:`; iOS-sim build → `[zapp] build complete:` (no menu icons on iOS, just confirms no link break).
- Manual smoke (hello-world): an `sf:` icon on a menu item tints with menu text (and flips in dark mode); a file-path PNG shows full color; a `data:` URL (canvas-generated) renders; the same `icon` field works in an app menu, a context menu, and a tray menu; a bad path logs + renders text-only (no crash, no "?").

## Non-goals (v1)

- **Sliders / custom-view (NSMenuItem.view) menu items** — separate future feature (typed widget kinds + value-change events).
- **Top-level menu-bar title icons** — items only; menu-bar titles stay text.
- **Changing the tray status-bar icon resolver** (`apply_icon`) — left as-is; shared-resolver adoption is a follow-up.
- **Windows / iOS menu icons** — iOS menus are no-op; Windows menu parity rides #167.
- No raw `iconBytes: Uint8Array` field (data-URL is the byte channel).

## Related

- [[project_menu_item_icons]] — the captured design this realizes (sf:/path/bytes + template flag).
- [[project_ios_icon_and_tray_fixes]] — the tray `template:true` white-blob footgun that motivates the smart per-source template default.
- [[reference_ios_symbol_parity_gate]] — if `zapp_resolve_icon` ends up referenced from `.zc`, it needs an iOS def (likely `.m`-only here, so N/A — confirm in plan).
- [[feedback_native_first_implementation]] — the C → Zen-C → router → TS → docs chain (here it's mostly TS field + native builders; no new router route — menus already route).
