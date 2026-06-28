# Toolbar Placement Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-item `placement: "leading" | "center" | "trailing"` to toolbar items so one `ToolbarItemDef` lays out correctly on macOS today (sorted into slots with auto-flexible-space brackets) and carries the metadata an iOS nav-bar will consume in a later cycle.

**Architecture:** Per-item optional `placement` (default `"leading"`) added to every top-level toolbar item def, threaded TS → wire JSON → Nim → native. macOS (`darwin/toolbar.m`) buckets the parsed identifiers into leading/center/trailing (preserving within-group order) and concatenates them with `NSToolbarFlexibleSpaceItem` auto-inserted between non-empty groups. iOS toolbar stays a no-op stub this cycle. The kitchen-sink shell toolbar migrates from manual `flexibleSpace` to `placement` and is the macOS no-regression smoke.

**Tech Stack:** TypeScript (runtime), Nim (native/nim, ORC), Objective-C (darwin AppKit `NSToolbar`), Bun (tests/build).

## Global Constraints

- Branch `feat/nim-native`, kept UNMERGED. Commit on it directly — no worktree, no `git commit --amend`, no merge.
- Commit trailer EXACTLY: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- Per-file `git add` ONLY — never `git add -A`/`.`. Pre-existing unrelated WIP must stay unstaged.
- Bun, never Node.
- Native-first parity: the same field exists TS ↔ Nim ↔ native, in one PR; Nim stays faithful to the wire contract.
- NO iOS simulator interaction in-session — build-only gates + human smoke on the user's device/sim.
- macOS is the parity reference — it must NOT regress (the migrated kitchen-sink toolbar renders identically).
- `placement` is **structural** — it is NOT added to `ToolbarItemPatch` / `TOOLBAR_PATCH_KEYS` (you cannot move an item between slots via `updateItem`; that is a `setItems` op).
- Slots this cycle: `leading` / `center` / `trailing`. `bottom` is deferred (additive later).
- Default placement is `"leading"`. Both TS and Nim ALWAYS emit `placement` on every item (keeps the wire + round-trip simple).

Per-task gates (run all, report results):
- `bun run check`
- `bun test cli/src`
- `bun run test:native`
- iOS compile: `cd kitchen-sink && bun run build --platform ios` → expect `[zapp] build complete:`
- macOS build: `cd kitchen-sink && bun run build` → expect `[zapp] build complete:`

---

## File Structure

| File | Responsibility |
|---|---|
| `runtime/window.ts` | `ToolbarPlacement` type; `placement?` on each top-level item def; `normalizeToolbar` validates + emits `placement` per item. |
| `runtime/toolbar.test.ts` | TS unit test — `normalizeToolbar` emits `placement` (incl. default) + rejects invalid. |
| `native/nim/window.nim` | `ToolbarPlacement` enum; `placement` field on `ToolbarItemOpt`; serialize emits it, parse reads it. |
| `native/nim/tests/windowmanager_test.nim` | Nim unit test — placement serialize→parse round-trip. |
| `native/platform/darwin/toolbar.m` | placement bucket + concat with auto-flexSpace in `zapp_toolbar_parse_items`. |
| `native/platform/ios/toolbar.m` | UNCHANGED (stubs) — explicitly do not touch. |
| `kitchen-sink/src/shell/toolbar-def.ts` | migrate `shellToolbar()` to `placement`; remove the two manual `flexibleSpace`. |
| `docs/api-reference.md` | document `placement` in §"Toolbar (macOS)" (~line 1157). |

---

## Task 1: TS — placement field + normalizeToolbar threading + validation

**Files:**
- Modify: `runtime/window.ts` (item def interfaces ~321-430; `normalizeToolbar` ~820-963)
- Test: `runtime/toolbar.test.ts`

**Interfaces:**
- Produces: `type ToolbarPlacement = "leading" | "center" | "trailing"`; every top-level item def gains `placement?: ToolbarPlacement`; `normalizeToolbar` wire JSON now includes `"placement"` on every item object (default `"leading"`).
- Consumes: nothing from later tasks.

- [ ] **Step 1: Write failing tests** in `runtime/toolbar.test.ts`

Add these cases (match the file's existing test style — it imports `normalizeToolbar` from `./window`). Place them in the existing describe/suite or as new `test(...)` calls:

```ts
test("normalizeToolbar emits placement (default leading) on every item", () => {
  const { json } = normalizeToolbar(
    { items: [
      { type: "toggleSidebar" },
      { id: "compose", label: "Compose" },
      { id: "status", type: "label", text: "Hi", placement: "center" },
      { id: "filter", label: "Filter", placement: "trailing" },
    ] },
    /* hasSidebar */ true,
    /* hasInspector */ false,
  );
  const wire = JSON.parse(json);
  expect(wire.items.map((i: any) => i.placement)).toEqual([
    "leading", "leading", "center", "trailing",
  ]);
});

test("normalizeToolbar rejects an invalid placement", () => {
  expect(() =>
    normalizeToolbar(
      { items: [{ id: "x", label: "X", placement: "top" as any }] },
      false, false,
    ),
  ).toThrow(/invalid placement/);
});
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `bun test runtime/toolbar.test.ts`
Expected: FAIL — `placement` is `undefined` on wire items / no throw on `"top"`.

- [ ] **Step 3: Add the type + field**

In `runtime/window.ts`, add the type near the other toolbar types (e.g. just above `ToolbarSegmentDef` ~line 319):

```ts
/** Which toolbar slot an item belongs to. macOS sorts items into these slots
 *  (leading → center → trailing) with flexible space auto-inserted between
 *  non-empty groups; iOS maps them to navigation-bar leading/title/trailing
 *  (a later cycle). Default "leading". */
export type ToolbarPlacement = "leading" | "center" | "trailing";
```

Add `placement?: ToolbarPlacement;` to EACH top-level item def interface (NOT `ToolbarSegmentDef`, which is a segmented sub-item, and NOT group sub-items): `ToolbarButtonDef`, `ToolbarSegmentedDef`, `ToolbarGroupDef`, `ToolbarTrackingSepDef`, `ToolbarSystemDef`, `ToolbarLabelDef`. Use this doc-commented field on each:

```ts
  /** Toolbar slot. Default "leading". macOS sorts by placement; iOS (later)
   *  maps to nav-bar slots. */
  placement?: ToolbarPlacement;
```

- [ ] **Step 4: Validate + emit placement in `normalizeToolbar`**

In `normalizeToolbar`, right after `const type = it.type ?? "button";` (~line 843) add:

```ts
    const placement: ToolbarPlacement = it.placement ?? "leading";
    if (placement !== "leading" && placement !== "center" && placement !== "trailing") {
      throw new Error(`[zapp] toolbar: invalid placement "${placement}" — use "leading", "center", or "trailing"`);
    }
```

Then add `placement` to EVERY object pushed into `items`. The eight push sites and their new form:

```ts
// toggleSidebar
items.push({ type, placement });
// toggleInspector
items.push({ type, placement });
// trackingSeparator
items.push({ type, pane, placement });
// space / flexibleSpace
items.push({ type, placement });
// label
items.push({ type: "label", id: it.id, text: it.text, placement });
```

For the three branches that build a named object before pushing, set the field before the push:

```ts
// segmented: after building `seg`, before items.push(seg):
seg.placement = placement;
// group: after building `g`, before items.push(g):
g.placement = placement;
// button: after building `wire` (and its optional fields), before items.push(wire):
wire.placement = placement;
```

Do NOT touch `normalizeToolbarPatch` or `TOOLBAR_PATCH_KEYS` — placement is structural.

- [ ] **Step 5: Run tests, verify they pass**

Run: `bun test runtime/toolbar.test.ts`
Expected: PASS (both new cases + all existing).

- [ ] **Step 6: Gates**

Run: `bun run check` (expect clean) and `bun test cli/src` (expect pass).

- [ ] **Step 7: Commit**

```bash
git add runtime/window.ts runtime/toolbar.test.ts
git commit -m "$(cat <<'EOF'
feat(toolbar): per-item placement (leading/center/trailing) in the TS API

Add ToolbarPlacement + a placement? field on every top-level toolbar item def
(default "leading"); normalizeToolbar validates it and emits it on every wire
item. Structural — not added to ToolbarItemPatch (moving slots = setItems).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Nim — ToolbarPlacement enum + field + serialize/parse parity

**Files:**
- Modify: `native/nim/window.nim` (enums ~60-90; `ToolbarItemOpt` ~99-115; `serializeToolbar` ~421-474; `parseToolbarJson` ~478-554)
- Test: `native/nim/tests/windowmanager_test.nim`

**Interfaces:**
- Consumes (wire contract from Task 1): each item JSON object has a `"placement"` string (`"leading"`/`"center"`/`"trailing"`).
- Produces: `ToolbarItemOpt.placement: ToolbarPlacement`; serialize emits `"placement"` on every item; parse reads it (default `Leading`).

- [ ] **Step 1: Write the failing test** in `native/nim/tests/windowmanager_test.nim`

Add a new `block:` near the other toolbar test blocks (after the segmented round-trip block ~line 240):

```nim
block:
  # placement round-trips (leading default + center/trailing)
  let t = ToolbarOptions(style: ToolbarStyle.Unified, items: @[
    ToolbarItemOpt(`type`: "toggleSidebar"),                              # default Leading
    ToolbarItemOpt(`type`: "button", id: "status", label: "Hi",
                   placement: ToolbarPlacement.Center),
    ToolbarItemOpt(`type`: "button", id: "filter", label: "Filter",
                   placement: ToolbarPlacement.Trailing),
  ])
  let s = serializeToolbar(t)
  doAssert "\"placement\":\"leading\"" in s, "default placement must serialize as leading"
  doAssert "\"placement\":\"center\"" in s
  doAssert "\"placement\":\"trailing\"" in s
  doAssert parseToolbarJson(s) == t, "parse(serialize(t)) must round-trip placement"
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `bun run test:native` (or the project's Nim test runner for `windowmanager_test.nim`)
Expected: FAIL — `ToolbarPlacement` undefined / `placement` field missing.

- [ ] **Step 3: Add the enum + field**

In `native/nim/window.nim`, add the enum next to the other toolbar enums (e.g. just below `ToolbarControlRepresentation` ~line 70). Follow the `{.pure.}` + string-value convention:

```nim
  ToolbarPlacement* {.pure.} = enum    ## toolbar slot (macOS sort / future iOS nav-bar)
    Leading = "leading", Center = "center", Trailing = "trailing"
```

Add the field to `ToolbarItemOpt` (default `Leading`), e.g. after `pane*: string`:

```nim
    placement*: ToolbarPlacement = ToolbarPlacement.Leading   ## toolbar slot; default Leading
```

- [ ] **Step 4: Emit placement in `serializeToolbar`**

Every `of` branch in the `case it.type` adds exactly one item to `items`. After the `case` statement closes (still inside `for it in t.items`, before the loop ends), append placement to the just-added item:

```nim
    items[^1]["placement"] = %($it.placement)
```

(Place this as the last statement of the loop body, after the whole `case` block.)

- [ ] **Step 5: Read placement in `parseToolbarJson`**

In `parseToolbarJson`, just before `result.items.add(item)` (the last line of the per-item loop ~line 554), read placement (default `Leading`):

```nim
    item.placement = (if jHasStr(itn, "placement"):
      enumFromStr[ToolbarPlacement](jStr(itn, "placement"), ToolbarPlacement.Leading)
      else: ToolbarPlacement.Leading)
```

- [ ] **Step 6: Run the test, verify it passes**

Run: `bun run test:native`
Expected: PASS — the new block + all existing toolbar round-trip blocks.

- [ ] **Step 7: Gates**

Run: `bun run check` and `bun test cli/src` (both should still pass — no TS change here).

- [ ] **Step 8: Commit**

```bash
git add native/nim/window.nim native/nim/tests/windowmanager_test.nim
git commit -m "$(cat <<'EOF'
feat(toolbar): ToolbarPlacement enum + field in Nim, serialize/parse parity

Mirror the TS placement field on ToolbarItemOpt (default Leading); serialize
emits "placement" on every item, parse reads it. Round-trip unit test added.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Native macOS — placement sort + auto-flexSpace bracketing

**Files:**
- Modify: `native/platform/darwin/toolbar.m` (`zapp_toolbar_parse_items` ~452-510)
- Do NOT touch: `native/platform/ios/toolbar.m` (stubs — placement rides in the JSON; consumed by a future iOS cycle).

**Interfaces:**
- Consumes (wire contract): each item dict has a `"placement"` string (default to `"leading"` when absent — native Zen-C callers may omit it).
- Produces: the returned `NSArray<NSToolbarItemIdentifier>` is ordered `leading → flexSpace → center → flexSpace → trailing`, flexSpace inserted only between non-empty groups.

**Background:** `zapp_toolbar_parse_items` currently appends every item's identifier to a single `ids` array in source order, and fills the `buttons` (id→def) registry. The ONLY change is to route each identifier into a leading/center/trailing bucket (by `def[@"placement"]`, default `"leading"`), then concatenate the buckets with auto-flexSpace. The `buttons` registry, the system-item identifier mapping, and all dedup checks stay intact.

- [ ] **Step 1: Bucket by placement instead of one flat array**

Replace the single `NSMutableArray<NSToolbarItemIdentifier>* ids` with three buckets, and route every `addObject:` to the bucket chosen at the top of the loop. Read `placement` once per item:

```objc
static NSArray<NSToolbarItemIdentifier>* zapp_toolbar_parse_items(
    NSArray* items, NSMutableDictionary<NSString*, NSDictionary*>* buttons) {
    NSMutableArray<NSToolbarItemIdentifier>* leading = [NSMutableArray array];
    NSMutableArray<NSToolbarItemIdentifier>* center = [NSMutableArray array];
    NSMutableArray<NSToolbarItemIdentifier>* trailing = [NSMutableArray array];
    for (NSDictionary* def in items) {
        if (![def isKindOfClass:[NSDictionary class]]) continue;
        NSString* type = [def[@"type"] isKindOfClass:[NSString class]] ? def[@"type"] : @"button";
        // Route this item to its slot bucket (default leading). Dedup of system
        // items must consider all three buckets, so check `bucketFor` membership.
        NSString* placement = [def[@"placement"] isKindOfClass:[NSString class]] ? def[@"placement"] : @"leading";
        NSMutableArray<NSToolbarItemIdentifier>* bucket =
            [placement isEqualToString:@"center"] ? center :
            [placement isEqualToString:@"trailing"] ? trailing : leading;
        // ... existing per-type branches, but: every `[ids addObject:X]`
        //     becomes `[bucket addObject:X]`, and every dedup guard
        //     `[ids containsObject:X]` becomes a helper that checks all three.
        ...
    }
    ...
}
```

For the dedup guards on `toggleSidebar` / `toggleInspector` / `trackingSeparator` (which currently use `[ids containsObject:...]`), add a small file-scope helper and use it so an item is never added twice across buckets:

```objc
static BOOL zapp_toolbar_has_id(NSArray* a, NSArray* b, NSArray* c, NSString* x) {
    return [a containsObject:x] || [b containsObject:x] || [c containsObject:x];
}
```

e.g. `if (!zapp_toolbar_has_id(leading, center, trailing, NSToolbarToggleSidebarItemIdentifier)) [bucket addObject:NSToolbarToggleSidebarItemIdentifier];`. The `buttons[...]` existence checks (segmented/group/label/button) already dedup by registry and stay unchanged — only `[ids addObject:X]` → `[bucket addObject:X]`.

- [ ] **Step 2: Concatenate with auto-flexSpace between non-empty groups**

Replace `return ids;` with:

```objc
    NSMutableArray<NSToolbarItemIdentifier>* out = [NSMutableArray array];
    [out addObjectsFromArray:leading];
    if (center.count > 0) {
        if (out.count > 0) [out addObject:NSToolbarFlexibleSpaceItemIdentifier];
        [out addObjectsFromArray:center];
        if (trailing.count > 0) [out addObject:NSToolbarFlexibleSpaceItemIdentifier];
        [out addObjectsFromArray:trailing];
    } else if (trailing.count > 0) {
        if (out.count > 0) [out addObject:NSToolbarFlexibleSpaceItemIdentifier];
        [out addObjectsFromArray:trailing];
    }
    return out;
```

This yields: leading-only → flat (unchanged); leading+trailing → `leading | flex | trailing`; leading+center+trailing → `leading | flex | center | flex | trailing` (standard NSToolbar centering). Within-bucket order is preserved (stable). The author's explicit `space`/`flexibleSpace` items remain valid inside a bucket.

- [ ] **Step 3: Build macOS, verify it compiles**

Run: `cd kitchen-sink && bun run build`
Expected: `[zapp] build complete:` (a fresh binary).

- [ ] **Step 4: Build iOS (parity gate — ios/toolbar.m untouched, must still compile)**

Run: `cd kitchen-sink && bun run build --platform ios`
Expected: `[zapp] build complete:`.

- [ ] **Step 5: Gates**

Run: `bun run check`; `bun test cli/src`; `bun run test:native` (all pass — no TS/Nim change in this task).

- [ ] **Step 6: Commit**

```bash
git add native/platform/darwin/toolbar.m
git commit -m "$(cat <<'EOF'
feat(toolbar): macOS honors placement — sort into slots + auto flexible space

zapp_toolbar_parse_items buckets identifiers by placement (leading/center/
trailing, default leading), preserving within-slot order, then concatenates
with NSToolbarFlexibleSpaceItem auto-inserted between non-empty groups
(leading | flex | center | flex | trailing). ios/toolbar.m unchanged (stubs).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Kitchen-sink migration + docs + macOS visual smoke gate

**Files:**
- Modify: `kitchen-sink/src/shell/toolbar-def.ts` (`shellToolbar` ~52-145)
- Modify: `docs/api-reference.md` (§"Toolbar (macOS)" ~line 1157)

**Interfaces:**
- Consumes: `placement?` on item defs (Task 1); macOS placement layout (Task 3).

- [ ] **Step 1: Migrate `shellToolbar()` to placement**

In `kitchen-sink/src/shell/toolbar-def.ts`, set `placement` on each item per the spec layout and REMOVE the two `{ type: "flexibleSpace" }` items (now auto-inserted between groups). Target:

- **leading** (default — may omit `placement` or set it explicitly for clarity): `toggleSidebar`, `trackingSeparator` (sidebar), `compose`, `inbox`
- **center:** `group:nav`, `segmented:view`, `segmented:fmt`
- **trailing:** `filter`, `label:status`, `trackingSeparator` (inspector), `toggleInspector`

Concretely: add `placement: "center"` to the `group:nav`, `segmented:view`, and `segmented:fmt` items; add `placement: "trailing"` to `filter`, the `label:status` item, the inspector `trackingSeparator`, and `toggleInspector`. Delete the two standalone `{ type: "flexibleSpace" }` entries. Leave the leading items as-is (default leading). Do not change ids, actions, or any other field.

- [ ] **Step 2: Build macOS + verify the toolbar renders**

Run: `cd kitchen-sink && bun run build`
Expected: `[zapp] build complete:`.

- [ ] **Step 3: Document `placement` in api-reference**

In `docs/api-reference.md`, in §"Toolbar (macOS)" (~line 1157), add a short subsection documenting:
- `placement?: "leading" | "center" | "trailing"` on toolbar items, default `"leading"`.
- macOS mapping: items are grouped by placement and rendered `leading | flexibleSpace | center | flexibleSpace | trailing` (flexible space auto-inserted between non-empty groups); within a slot, array order is preserved and `space`/`flexibleSpace` remain usable.
- Not patchable via `updateItem` (structural — re-`setItems` to move an item between slots).
- iOS-future note: placement is carried for the upcoming native iOS navigation-bar toolbar (a later cycle); the `bottom` slot will be added then.

Use prose matching the surrounding doc style; no code-fence required beyond a one-line example like `{ id: "filter", label: "Filter", placement: "trailing" }`.

- [ ] **Step 4: Full gates**

Run, expecting pass / `[zapp] build complete:` for each:
- `bun run check`
- `bun test cli/src`
- `bun run test:native`
- `cd kitchen-sink && bun run build --platform ios`
- `cd kitchen-sink && bun run build`

- [ ] **Step 5: Commit**

```bash
git add kitchen-sink/src/shell/toolbar-def.ts docs/api-reference.md
git commit -m "$(cat <<'EOF'
feat(toolbar): migrate kitchen-sink shell toolbar to placement + docs

shellToolbar() uses placement (center: nav/view/fmt; trailing: filter/status/
inspector toggle) and drops the two manual flexibleSpace items. Document
placement + the macOS slot mapping in api-reference.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 6: HUMAN VISUAL SMOKE GATE (macOS — the risk gate)**

STOP and hand to the controller for a human smoke. The macOS kitchen-sink toolbar must render **identically to before the migration**:
- leading group (sidebar toggle, compose, inbox) at the left;
- center group (nav, view, fmt) centered;
- trailing group (filter, status label, inspector toggle) at the right;
- dynamic ops still work (Toolbar section: badge increment/clear, enabled toggle, status label text, remove + re-add);
- `trackingSeparator`s still track the sidebar/inspector dividers.
iOS smoke: the HTML stand-in is unchanged and the app launches (toolbar ops no-op, no crash).

---

## Self-Review

**Spec coverage:** placement type + field (Task 1 TS, Task 2 Nim); macOS honor (Task 3); not-patchable (Task 1, explicit); kitchen-sink migration + docs (Task 4); tests (Task 1 TS, Task 2 Nim); iOS untouched (Task 3 explicit); three slots, bottom deferred (Global Constraints). All spec sections map to a task.

**Placeholder scan:** none — every code step shows the exact change.

**Type consistency:** `ToolbarPlacement` (TS) ↔ `ToolbarPlacement` enum (Nim) with identical wire strings `"leading"/"center"/"trailing"`; default `"leading"`/`Leading` everywhere; wire key `"placement"` consistent across TS emit, Nim emit/parse, and macOS read.
