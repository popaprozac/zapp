# AppKit Toolbar Grouping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `NSToolbarItemGroup` to Zapp's toolbar in two flavors — `type: "segmented"` (a selectable segmented control) and `type: "group"` (a cluster of full items that can collapse to an overflow menu) — with TS↔Nim parity, live updates, and a `TOOLBAR_GROUP_SELECTED` event.

**Architecture:** Two new `ToolbarItemDef.type` values flow as wire-JSON keys: TS (`normalizeToolbar`) and Nim (`serializeToolbar`) both emit them; `toolbar.m` builds an `NSToolbarItemGroup` via the convenience constructor (segmented) or the `subitems` property (group). Segmented selection emits a new string event `window:toolbar-group-selected`; the per-segment `action: () => void` primitive matches existing menu/toolbar items.

**Tech Stack:** TypeScript (Bun test), Nim (`std/json`, `unittest`), Objective-C (AppKit `NSToolbarItemGroup`, macOS 10.15 SDK), Zapp CLI build.

## Global Constraints

- Branch `feat/nim-native`; do NOT merge or switch branches.
- Commit trailer on every commit: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- **Staging: explicit per-file `git add` only. NEVER `git add -A`/`git add .`** — unrelated WIP exists under `assets/`, `benchmarks/`, `vendor/`, `spikes/`.
- Always use Bun, never Node.
- `NSToolbarItemGroup` usage is gated `if (@available(macOS 10.15, *))` (the toolbar's existing floor); below it the group item is dropped with an NSLog warning. NO macOS-26 gate, NO fallback matrix.
- "macOS build success" = LAST line `[zapp] build complete: …` (Vite's `✓ built` is NOT success).
- `selected` is ALWAYS an array on the wire (`[]`/`[n]`/`[a,b]`); TS normalizes a `number` to `[number]`; Nim uses `seq[int]`.
- Groups may not nest (SDK rule): a `"group"`/`"segmented"` item inside another group's `items` is rejected.
- T5 ends in a HUMAN VISUAL smoke gate — pause and hand off; do not self-certify it.

## Wire JSON contract (shared TS + Nim, parsed in toolbar.m)

```json
{ "type": "segmented", "id": "view", "selectionMode": "one", "selected": [1],
  "controlRepresentation": "automatic",
  "segments": [ {"id":"grid","icon":"sf:square.grid.2x2"}, {"id":"list","icon":"sf:list.bullet"} ] }

{ "type": "group", "id": "nav", "controlRepresentation": "collapsed",
  "items": [ {"type":"button","id":"back","icon":"sf:chevron.left"},
             {"type":"button","id":"fwd","icon":"sf:chevron.right"} ] }
```

`selectionMode` ∈ `"momentary"|"one"|"any"` (omit ⇒ momentary). `controlRepresentation` ∈ `"automatic"|"expanded"|"collapsed"` (omit ⇒ automatic). Each segment: `{id?, label?, icon?, enabled?}` (label **or** icon).

## File Structure

- `runtime/events.ts` — add `WindowEvent.TOOLBAR_GROUP_SELECTED = 20` + name-map entry.
- `runtime/window.ts` — `ToolbarSegmentDef`, `ToolbarItemDef` type union + group fields, `ToolbarItemPatch` (`selected`/`controlRepresentation`), `normalizeToolbar`/`normalizeToolbarPatch`, segment-action registration + the `TOOLBAR_GROUP_SELECTED` wiring.
- `native/nim/window.nim` — `ToolbarGroupSelectionMode`/`ToolbarControlRepresentation` enums, `ToolbarSegmentOpt`, `ToolbarItemOpt` fields, `serializeToolbar`/`parseToolbarJson`.
- `native/platform/darwin/toolbar.m` — segmented + group build arms, `zapp_toolbar_emit_group_select`, `updateItem` selection.
- `runtime/toolbar.test.ts`, `native/nim/tests/windowmanager_test.nim` — tests.
- `kitchen-sink/src/shell/toolbar-def.ts`, `kitchen-sink/src/sections/toolbar.ts` — showcase.
- `docs/api-reference.md`, `docs/native-ui-strategy.md` — docs.

---

## Task 1: TS — segmented type + event + normalize (TDD)

**Files:**
- Modify: `runtime/events.ts` (enum ~22-59, name map ~86-107)
- Modify: `runtime/window.ts` (`ToolbarItemDef` ~328, `ToolbarItemPatch` ~370, `normalizeToolbar` ~583, `TOOLBAR_PATCH_KEYS` ~691, `normalizeToolbarPatch` ~665, segment-action wiring near `wireToolbarClicks` ~486-499)
- Test: `runtime/toolbar.test.ts`

**Interfaces:**
- Produces (consumed by Task 2 Nim parity + Task 3 native): wire keys per the contract above. `WindowEvent.TOOLBAR_GROUP_SELECTED = 20` → `"window:toolbar-group-selected"`. Segment-action registry keyed `${windowId}:${groupId}:${index}`.

- [ ] **Step 1: Add the event (no test — enum/data)**

In `runtime/events.ts`, after `INSPECTOR_RESIZED = 19,` (line 58) inside `enum WindowEvent`:

```ts
  /** Fires when a segmented toolbar group's selection changes (selectOne/
   * selectAny). Broadcast to ALL webviews + workers (toolbar-click pattern).
   * Payload: `{ windowId, id, index, selected }` — `selected` is the index's
   * new state (always true for selectOne; the toggle result for selectAny).
   * Momentary groups do NOT fire this — only their per-segment `action`. */
  TOOLBAR_GROUP_SELECTED = 20,
```

In `WINDOW_EVENT_NAMES` (after the `INSPECTOR_RESIZED` line ~106):

```ts
  [WindowEvent.TOOLBAR_GROUP_SELECTED]: "window:toolbar-group-selected",
```

- [ ] **Step 2: Write failing tests for normalize**

Append to `runtime/toolbar.test.ts`:

```ts
describe("normalizeToolbar segmented (grouping)", () => {
  it("emits a segmented group with segments, selectionMode, selected[], controlRepresentation", () => {
    const { json } = normalizeToolbar({ items: [{
      type: "segmented", id: "view", selectionMode: "one", selected: 1,
      controlRepresentation: "automatic",
      segments: [{ id: "grid", icon: "sf:square.grid.2x2" }, { id: "list", icon: "sf:list.bullet" }],
    }] }, false, false);
    const it0 = JSON.parse(json).items[0];
    expect(it0.type).toBe("segmented");
    expect(it0.id).toBe("view");
    expect(it0.selectionMode).toBe("one");
    expect(it0.selected).toEqual([1]);              // number → [number]
    expect(it0.controlRepresentation).toBe("automatic");
    expect(it0.segments).toEqual([{ id: "grid", icon: "sf:square.grid.2x2" }, { id: "list", icon: "sf:list.bullet" }]);
  });
  it("defaults selectionMode omitted; selected[] passthrough for selectAny", () => {
    const it0 = JSON.parse(normalizeToolbar({ items: [{
      type: "segmented", id: "fmt", selectionMode: "any", selected: [0, 2],
      segments: [{ label: "B" }, { label: "I" }, { label: "U" }],
    }] }, false, false).json).items[0];
    expect(it0.selected).toEqual([0, 2]);
    expect(it0.selectionMode).toBe("any");
  });
  it("registers per-segment actions and returns them", () => {
    const fn = () => {};
    const { actions } = normalizeToolbar({ items: [{
      type: "segmented", id: "view",
      segments: [{ id: "grid", icon: "sf:a", action: fn }, { id: "list", icon: "sf:b" }],
    }] }, false, false);
    expect(actions.get("view:0")).toBe(fn);          // keyed groupId:index
  });
  it("rejects a segmented item with no segments / no id", () => {
    expect(() => normalizeToolbar({ items: [{ type: "segmented", segments: [{ label: "x" }] } as any] }, false, false)).toThrow(/id/);
    expect(() => normalizeToolbar({ items: [{ type: "segmented", id: "x", segments: [] }] }, false, false)).toThrow(/segment/);
  });
});

describe("normalizeToolbarPatch selection (grouping)", () => {
  it("emits selected[] and controlRepresentation", () => {
    const p = JSON.parse(normalizeToolbarPatch("view", { selected: 2 }).json);
    expect(p.selected).toEqual([2]);
    const p2 = JSON.parse(normalizeToolbarPatch("view", { controlRepresentation: "collapsed" }).json);
    expect(p2.controlRepresentation).toBe("collapsed");
  });
});
```

- [ ] **Step 3: Run — expect FAIL**

Run: `cd /Users/zach/code/zapp && bun test runtime/toolbar.test.ts`
Expected: FAIL (segmented not handled; `actions.get("view:0")` undefined).

- [ ] **Step 4: Add the types**

In `runtime/window.ts`, before `interface ToolbarItemDef` (~line 327) add:

```ts
/** One segment of a `type: "segmented"` toolbar group. A menu-like item:
 *  same `action: () => void` primitive as MenuItemDef/ToolbarItemDef. */
export interface ToolbarSegmentDef {
  /** Optional id (currently informational; segments route by index). */
  id?: string;
  /** Segment label OR icon — the convenience control takes titles or images. */
  label?: string;
  icon?: string;
  /** Default true. */
  enabled?: boolean;
  /** Fires when this segment is pressed (momentary) or becomes selected. */
  action?: () => void;
}
```

In `interface ToolbarItemDef`, widen `type` and add fields. Change the `type?` line (~340) to include the new kinds:

```ts
  type?: "button" | "toggleSidebar" | "toggleInspector" | "trackingSeparator" | "space" | "flexibleSpace" | "segmented" | "group";
```

Add after the W2 `bordered?` field (end of the interface, ~358):

```ts
  /** "segmented": the segments of the control. label OR icon each. */
  segments?: ToolbarSegmentDef[];
  /** "segmented": selection behavior. Default "momentary". */
  selectionMode?: "one" | "any" | "momentary";
  /** "segmented": initial selection — index ("one") or indices ("any").
   *  Ignored for "momentary". */
  selected?: number | number[];
  /** "group": clustered full items (one level — no nested groups). */
  items?: ToolbarItemDef[];
  /** "segmented" + "group": how the control collapses. Default "automatic". */
  controlRepresentation?: "automatic" | "expanded" | "collapsed";
```

In `interface ToolbarItemPatch` (after `bordered?`, ~381):

```ts
  /** "segmented": set selection live — index ("one") or indices ("any"). */
  selected?: number | number[];
  controlRepresentation?: "automatic" | "expanded" | "collapsed";
```

- [ ] **Step 5: Add a selected→array helper + handle "segmented" in normalizeToolbar**

In `runtime/window.ts`, just above `export function normalizeToolbar(` (~583) add:

```ts
/** Normalize a `selected` value to the wire array form ([]/[n]/[a,b]). */
function selectedToWire(s: number | number[] | undefined): number[] {
  if (s === undefined) return [];
  return Array.isArray(s) ? s.slice() : [s];
}
```

In `normalizeToolbar`, the loop handles known `type`s before the custom-button fallthrough. Add a `segmented` branch right before the `if (!item.id) throw … button items require an "id"` line (~634):

```ts
    if (type === "segmented") {
      if (!item.id) throw new Error('[zapp] toolbar: "segmented" items require an "id"');
      if (!item.segments || item.segments.length === 0) throw new Error('[zapp] toolbar: "segmented" requires a non-empty "segments" array');
      if (seen.has(item.id)) throw new Error(`[zapp] toolbar: duplicate item id "${item.id}"`);
      seen.add(item.id);
      const wireSegs = item.segments.map((s, i) => {
        if (s.action) actions.set(`${item.id}:${i}`, s.action);
        const w: Record<string, unknown> = {};
        if (s.id !== undefined) w.id = s.id;
        if (s.label !== undefined) w.label = s.label;
        if (s.icon !== undefined) w.icon = s.icon;
        if (s.enabled !== undefined) w.enabled = s.enabled;
        return w;
      });
      const seg: Record<string, unknown> = { type: "segmented", id: item.id, segments: wireSegs,
        selectionMode: item.selectionMode ?? "momentary", selected: selectedToWire(item.selected) };
      if (item.controlRepresentation !== undefined) seg.controlRepresentation = item.controlRepresentation;
      items.push(seg);
      continue;
    }
```

(`actions` is the same `Map` already returned by `normalizeToolbar`; the existing `TOOLBAR_CLICKED` wiring runs `actions.get(...)`. The segment key is `groupId:index`.)

- [ ] **Step 6: Patch keys + normalizeToolbarPatch**

In `TOOLBAR_PATCH_KEYS` (~691) add `"selected"`, `"controlRepresentation"`:

```ts
const TOOLBAR_PATCH_KEYS = new Set(["label", "icon", "enabled", "indicator", "menu", "action", "style", "tintColor", "badge", "bordered", "selected", "controlRepresentation"]);
```

In `normalizeToolbarPatch`, after the W2 `badge` line (~696):

```ts
  if (patch.selected !== undefined) wire.selected = selectedToWire(patch.selected);
  if (patch.controlRepresentation !== undefined) wire.controlRepresentation = patch.controlRepresentation;
```

- [ ] **Step 7: Wire the TOOLBAR_GROUP_SELECTED handler (run segment action)**

In `runtime/window.ts`, find `wireToolbarClicks()` (~489). Add a sibling `wireToolbarGroupSelect()` and call it wherever `wireToolbarClicks()` is called (the same three sites: `normalizeToolbar` result registration in `setItems` ~1043, the post-create `registerToolbarActions` ~1200, and `updateItem`/late paths). Add near `wireToolbarClicks`:

```ts
let toolbarGroupWired = false;
function wireToolbarGroupSelect(): void {
  if (toolbarGroupWired) return;
  toolbarGroupWired = true;
  getBridge().on(eventName(WindowEvent.TOOLBAR_GROUP_SELECTED), (payload: any) => {
    const fn = toolbarActions.get(`${payload?.windowId}:${payload?.id}:${payload?.index}`);
    if (fn) fn();
  });
}
```

Call `wireToolbarGroupSelect();` immediately after each existing `wireToolbarClicks();` call (so segment actions fire). The public `win.on(WindowEvent.TOOLBAR_GROUP_SELECTED, …)` subscription works for free via the bridge event.

(Note: `toolbarActions` keys for segments are `windowId:groupId:index`; `normalizeToolbar` produced `groupId:index`, so the per-window prefixing happens where the existing code does `toolbarActions.set(\`${windowId}:${id}\`, fn)` — mirror it for segment entries: when registering, the existing loop iterates `actions` (which now contains `groupId:index` keys) and prefixes `windowId:`. Verify the existing registration loop prefixes every `actions` entry with `${windowId}:` — it does at ~1044/1201 — so segment keys become `windowId:groupId:index` automatically.)

- [ ] **Step 8: Run tests — expect PASS**

Run: `cd /Users/zach/code/zapp && bun test runtime/toolbar.test.ts`
Expected: PASS (new + existing suites).

- [ ] **Step 9: Type-check**

Run: `cd /Users/zach/code/zapp && bunx tsc --noEmit -p tsconfig.json`
Expected: no NEW errors vs the known baseline.

- [ ] **Step 10: Commit**

```bash
cd /Users/zach/code/zapp
git add runtime/events.ts runtime/window.ts runtime/toolbar.test.ts
git commit -m "$(cat <<'EOF'
feat(toolbar): TS segmented group type + TOOLBAR_GROUP_SELECTED + normalize

type:"segmented" (segments/selectionMode/selected/controlRepresentation) with
per-segment action:()=>void registered by groupId:index; selected normalized to
a wire array; new WindowEvent.TOOLBAR_GROUP_SELECTED runs the selected segment's
action and is public-subscribable.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Nim — segmented parity + serialize/parse (TDD)

**Files:**
- Modify: `native/nim/window.nim` (enums ~58, `ToolbarItemOpt` ~75, `serializeToolbar` ~382, `parseToolbarJson` ~405)
- Test: `native/nim/tests/windowmanager_test.nim`

**Interfaces:**
- Consumes: the wire keys from Task 1 (`type:"segmented"`, `segments`, `selectionMode`, `selected[]`, `controlRepresentation`).
- Produces: `serializeToolbar` emits them; `parseToolbarJson` round-trips them.

- [ ] **Step 1: Write the failing round-trip test**

In `native/nim/tests/windowmanager_test.nim`, near the existing toolbar round-trip test add:

```nim
test "segmented toolbar group round-trips (grouping)":
  let t = ToolbarOptions(style: ToolbarStyle.Unified, items: @[
    ToolbarItemOpt(`type`: "segmented", id: "view",
      selectionMode: ToolbarGroupSelectionMode.One, selected: @[1],
      controlRepresentation: ToolbarControlRepresentation.Automatic,
      segments: @[
        ToolbarSegmentOpt(id: "grid", icon: "sf:square.grid.2x2", enabled: true),
        ToolbarSegmentOpt(id: "list", icon: "sf:list.bullet", enabled: true)]),
  ])
  let s = serializeToolbar(t)
  check parseToolbarJson(s) == t
  let root = parseJson(s)
  check root["items"][0]["type"].getStr == "segmented"
  check root["items"][0]["selectionMode"].getStr == "one"
  check root["items"][0]["selected"] == %*[1]
  check root["items"][0]["segments"][0]["icon"].getStr == "sf:square.grid.2x2"
```

- [ ] **Step 2: Run — expect FAIL (unknown enums/fields)**

Run: `cd /Users/zach/code/zapp && nim c -r --hints:off native/nim/tests/windowmanager_test.nim`
Expected: FAIL — `ToolbarGroupSelectionMode`/`ToolbarControlRepresentation`/`ToolbarSegmentOpt` undeclared; `ToolbarItemOpt` lacks the fields.

- [ ] **Step 3: Add enums + segment type**

In `native/nim/window.nim`, in the `type` block near `ToolbarStyle` (~58) add:

```nim
  ToolbarGroupSelectionMode* {.pure.} = enum   ## NSToolbarItemGroupSelectionMode
    Momentary = "momentary", One = "one", Any = "any"

  ToolbarControlRepresentation* {.pure.} = enum ## NSToolbarItemGroupControlRepresentation
    Automatic = "automatic", Expanded = "expanded", Collapsed = "collapsed"

  ToolbarSegmentOpt* = object                  ## mirrors TS ToolbarSegmentDef (data only)
    id*, label*, icon*: string
    enabled*: bool = true
```

Extend `ToolbarItemOpt` (after the W2 fields ~end of the object, near `bordered*`):

```nim
    segments*: seq[ToolbarSegmentOpt]            ## "segmented"
    selectionMode*: ToolbarGroupSelectionMode    ## default Momentary
    selected*: seq[int]                          ## indices; empty = none
    controlRepresentation*: ToolbarControlRepresentation  ## default Automatic
```

- [ ] **Step 4: Emit in serializeToolbar**

In `serializeToolbar` (~382), before the `else: # button (default)` branch, add a `segmented` case (the `case it.\`type\`` already dispatches on type — add an `of "segmented":` arm):

```nim
    of "segmented":
      var segs = newJArray()
      for sg in it.segments:
        var sj = newJObject()
        if sg.id.len > 0: sj["id"] = %sg.id
        if sg.label.len > 0: sj["label"] = %sg.label
        if sg.icon.len > 0: sj["icon"] = %sg.icon
        sj["enabled"] = %sg.enabled
        segs.add(sj)
      var w = %*{"type": "segmented", "id": it.id, "segments": segs,
                 "selectionMode": $it.selectionMode, "selected": %it.selected}
      if it.controlRepresentation != ToolbarControlRepresentation.Automatic:
        w["controlRepresentation"] = %($it.controlRepresentation)
      items.add(w)
```

(Always emit `selected` as a JSON array of the seq, and `selectionMode` as its string; emit `controlRepresentation` only when non-default so the round-trip with Automatic stays lossless. Emit `enabled` per-segment always, mirroring the existing always-emit-enabled convention.)

- [ ] **Step 5: Parse in parseToolbarJson**

In `parseToolbarJson` (~405), the per-item loop builds `ToolbarItemOpt`. After setting `item.\`type\``, handle the segmented fields (add inside the loop, after the existing `type` assignment):

```nim
    if item.`type` == "segmented":
      if jHasStr(itn, "selectionMode"):
        item.selectionMode = enumFromStr[ToolbarGroupSelectionMode](jStr(itn, "selectionMode"), ToolbarGroupSelectionMode.Momentary)
      item.controlRepresentation = (if jHasStr(itn, "controlRepresentation"):
        enumFromStr[ToolbarControlRepresentation](jStr(itn, "controlRepresentation"), ToolbarControlRepresentation.Automatic)
        else: ToolbarControlRepresentation.Automatic)
      let seln = itn{"selected"}
      if not seln.isNil and seln.kind == JArray:
        for v in seln:
          if v.kind == JInt: item.selected.add(v.getInt)
      let segn = itn{"segments"}
      if not segn.isNil and segn.kind == JArray:
        for sn in segn:
          if sn.kind != JObject: continue
          var sg = ToolbarSegmentOpt(enabled: true)
          if jHasStr(sn, "id"): sg.id = jStr(sn, "id")
          if jHasStr(sn, "label"): sg.label = jStr(sn, "label")
          if jHasStr(sn, "icon"): sg.icon = jStr(sn, "icon")
          if jHasBool(sn, "enabled"): sg.enabled = jBool(sn, "enabled", true)
          item.segments.add(sg)
```

- [ ] **Step 6: Run — expect PASS**

Run: `cd /Users/zach/code/zapp && nim c -r --hints:off native/nim/tests/windowmanager_test.nim`
Expected: PASS (new + existing round-trips).

- [ ] **Step 7: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/window.nim native/nim/tests/windowmanager_test.nim
git commit -m "$(cat <<'EOF'
feat(toolbar): Nim segmented group parity (serialize/parse)

ToolbarGroupSelectionMode + ToolbarControlRepresentation + ToolbarSegmentOpt;
ToolbarItemOpt gains segments/selectionMode/selected/controlRepresentation;
serializeToolbar emits + parseToolbarJson round-trips the segmented wire shape.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Native — segmented arm + emit + updateItem

**Files:**
- Modify: `native/platform/darwin/toolbar.m` (emit helpers ~95-135; `zapp_toolbar_parse_items` ~269; builder ~140-238; `darwin_toolbar_update_item` ~433-519)

**Interfaces:**
- Consumes: the stored def dict (`buttonsById[id]` holds the whole def, incl. `segments`/`selectionMode`/`selected`/`controlRepresentation`).
- Produces: an `NSToolbarItemGroup` segmented control; broadcasts `window:toolbar-group-selected` `{windowId,id,index,selected}`. No new exported symbols beyond `zapp_toolbar_emit_group_select` (file-internal `void`, called from the group action).

- [ ] **Step 1: Add the group-select emit helper**

In `native/platform/darwin/toolbar.m`, after `zapp_toolbar_emit_click` (~line 113), add (mirroring its broadcast):

```objc
// Broadcast window:toolbar-group-selected {windowId,id,index,selected} to all
// webviews + workers (same fan-out as toolbar-clicked).
void zapp_toolbar_emit_group_select(int32_t host_id, const char* group_id, int32_t index, bool selected) {
    if (!group_id) return;
    NSString* gid = [NSString stringWithUTF8String:group_id];
    NSString* js = [NSString stringWithFormat:
        @"(function(){var b=window.__zappBridge;"
        @"if(b&&b._onEvent)b._onEvent('window:toolbar-group-selected',"
        @"JSON.stringify({windowId:'win-%d',id:'%@',index:%d,selected:%@}));})();",
        host_id, gid, index, selected ? @"true" : @"false"];
    extern void darwin_webview_eval_all(const char* js);
    darwin_webview_eval_all([js UTF8String]);
    extern void worker_broadcast_eval_js(char* js);
    worker_broadcast_eval_js((char*)[js UTF8String]);
}
```

(Match the exact escaping/fan-out helpers `zapp_toolbar_emit_click` uses — copy its pattern; `gid` comes from a validated wire id so no extra escaping beyond what that function already relies on.)

- [ ] **Step 2: Register the segmented identifier in the parser**

In `zapp_toolbar_parse_items` (~269), the `else` (custom button) branch stores `buttons[itemId] = def`. Segmented items have `type:"segmented"` and an `id`, so add an explicit arm before the final `else` (after the `flexibleSpace` arm ~299):

```objc
        } else if ([type isEqualToString:@"segmented"]) {
            NSString* gid = [def[@"id"] isKindOfClass:[NSString class]] ? def[@"id"] : nil;
            if (gid.length == 0 || buttons[gid]) continue;
            [ids addObject:gid];
            buttons[gid] = def;   // carries segments/selectionMode/selected/controlRepresentation
```

- [ ] **Step 3: Build the segmented group in the item builder**

In `toolbar:itemForItemIdentifier:`, after fetching `NSDictionary* def = self.buttonsById[identifier];` and the `if (!def) return nil;` (~188), add a segmented branch BEFORE the menu/plain-button handling:

```objc
    if ([def[@"type"] isEqualToString:@"segmented"]) {
        if (@available(macOS 10.15, *)) {
            NSArray* segs = [def[@"segments"] isKindOfClass:[NSArray class]] ? def[@"segments"] : @[];
            NSString* modeStr = [def[@"selectionMode"] isKindOfClass:[NSString class]] ? def[@"selectionMode"] : @"momentary";
            NSToolbarItemGroupSelectionMode mode = [modeStr isEqualToString:@"one"] ? NSToolbarItemGroupSelectionModeSelectOne
                : ([modeStr isEqualToString:@"any"] ? NSToolbarItemGroupSelectionModeSelectAny : NSToolbarItemGroupSelectionModeMomentary);
            // Build titles or images. Prefer images when any segment has an icon.
            BOOL useImages = NO;
            for (NSDictionary* s in segs) if ([s[@"icon"] isKindOfClass:[NSString class]] && ((NSString*)s[@"icon"]).length) { useImages = YES; break; }
            NSMutableArray* labels = [NSMutableArray array];
            for (NSDictionary* s in segs) [labels addObject:([s[@"label"] isKindOfClass:[NSString class]] ? s[@"label"] : @"")];
            NSToolbarItemGroup* group;
            if (useImages) {
                NSMutableArray<NSImage*>* imgs = [NSMutableArray array];
                for (NSDictionary* s in segs) {
                    NSString* ic = [s[@"icon"] isKindOfClass:[NSString class]] ? s[@"icon"] : @"";
                    NSImage* im = ic.length ? zapp_resolve_icon(ic, 18.0, 1) : [[NSImage alloc] initWithSize:NSMakeSize(1,1)];
                    [imgs addObject:(im ?: [[NSImage alloc] initWithSize:NSMakeSize(1,1)])];
                }
                group = [NSToolbarItemGroup groupWithItemIdentifier:identifier images:imgs selectionMode:mode labels:labels target:self action:@selector(zappToolbarGroupChanged:)];
            } else {
                NSMutableArray<NSString*>* titles = [NSMutableArray array];
                for (NSDictionary* s in segs) [titles addObject:([s[@"label"] isKindOfClass:[NSString class]] ? s[@"label"] : @"")];
                group = [NSToolbarItemGroup groupWithItemIdentifier:identifier titles:titles selectionMode:mode labels:nil target:self action:@selector(zappToolbarGroupChanged:)];
            }
            NSString* repr = [def[@"controlRepresentation"] isKindOfClass:[NSString class]] ? def[@"controlRepresentation"] : @"automatic";
            group.controlRepresentation = [repr isEqualToString:@"expanded"] ? NSToolbarItemGroupControlRepresentationExpanded
                : ([repr isEqualToString:@"collapsed"] ? NSToolbarItemGroupControlRepresentationCollapsed : NSToolbarItemGroupControlRepresentationAutomatic);
            // initial selection
            NSArray* sel = [def[@"selected"] isKindOfClass:[NSArray class]] ? def[@"selected"] : @[];
            for (NSNumber* n in sel) { NSInteger i = n.integerValue; if (i >= 0 && i < (NSInteger)segs.count) [group setSelected:YES atIndex:i]; }
            // per-segment enabled
            for (NSUInteger i = 0; i < group.subitems.count && i < segs.count; i++) {
                NSNumber* en = [segs[i][@"enabled"] isKindOfClass:[NSNumber class]] ? segs[i][@"enabled"] : nil;
                group.subitems[i].enabled = en ? en.boolValue : YES;
            }
            return group;
        }
        NSLog(@"[zapp] toolbar: segmented group requires macOS 10.15 — item dropped");
        return nil;
    }
```

- [ ] **Step 4: Add the group-changed action**

Near `zappToolbarItemClicked:` (~260), add:

```objc
- (void)zappToolbarGroupChanged:(NSToolbarItemGroup*)sender {
    if (![sender isKindOfClass:[NSToolbarItemGroup class]]) return;
    NSInteger idx = sender.selectedIndex;
    // Momentary groups report -1; fall back to the highlighted segment if needed.
    if (idx < 0) { for (NSInteger i = 0; i < (NSInteger)sender.subitems.count; i++) if ([sender isSelectedAtIndex:i]) { idx = i; break; } }
    BOOL sel = (idx >= 0) ? [sender isSelectedAtIndex:idx] : NO;
    zapp_toolbar_emit_group_select(self.windowNumericId, [sender.itemIdentifier UTF8String], (int32_t)idx, sel);
}
```

(`idx` may be -1 for a momentary group where AppKit reports no persisted selection; the runtime keys actions by `groupId:index`, so momentary segments whose index can't be resolved won't fire — verified in the T5 human smoke. If the smoke shows momentary indices unresolved, read the sender's underlying `NSSegmentedControl.selectedSegment`; the fallback loop above covers the common case.)

- [ ] **Step 5: updateItem — apply live selection + representation**

In `darwin_toolbar_update_item` (~433), after the W2 trio block and before `[window.toolbar validateVisibleItems];` (~516), add:

```objc
        if (@available(macOS 10.15, *)) {
            if ([live isKindOfClass:[NSToolbarItemGroup class]]) {
                NSToolbarItemGroup* g = (NSToolbarItemGroup*)live;
                if ([patch[@"selected"] isKindOfClass:[NSArray class]]) {
                    for (NSInteger i = 0; i < (NSInteger)g.subitems.count; i++) [g setSelected:NO atIndex:i];
                    for (NSNumber* n in (NSArray*)patch[@"selected"]) { NSInteger i = n.integerValue; if (i >= 0 && i < (NSInteger)g.subitems.count) [g setSelected:YES atIndex:i]; }
                }
                NSString* repr = [patch[@"controlRepresentation"] isKindOfClass:[NSString class]] ? patch[@"controlRepresentation"] : nil;
                if (repr) g.controlRepresentation = [repr isEqualToString:@"expanded"] ? NSToolbarItemGroupControlRepresentationExpanded
                    : ([repr isEqualToString:@"collapsed"] ? NSToolbarItemGroupControlRepresentationCollapsed : NSToolbarItemGroupControlRepresentationAutomatic);
            }
        }
```

- [ ] **Step 6: Build macOS + iOS-sim**

Run:
```bash
cd /Users/zach/code/zapp/kitchen-sink && bun run build 2>&1 | tail -1
cd /Users/zach/code/zapp/kitchen-sink && bun run build --platform ios 2>&1 | tail -1
```
Expected: both `[zapp] build complete: …`.

- [ ] **Step 7: Commit**

```bash
cd /Users/zach/code/zapp
git add native/platform/darwin/toolbar.m
git commit -m "$(cat <<'EOF'
feat(macos): NSToolbarItemGroup segmented control + selection emit (grouping)

Build type:"segmented" via groupWithItemIdentifier:titles:/images:selectionMode:
labels:target:action:; controlRepresentation + initial selected; group action
broadcasts window:toolbar-group-selected {id,index,selected}; updateItem applies
live selected/controlRepresentation. macOS 10.15 gated.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Plain `group` flavor (subitems cluster) — TS + Nim + native

**Files:**
- Modify: `runtime/window.ts` (`normalizeToolbar` ~583), `runtime/toolbar.test.ts`
- Modify: `native/nim/window.nim` (`serializeToolbar`/`parseToolbarJson`), `native/nim/tests/windowmanager_test.nim`
- Modify: `native/platform/darwin/toolbar.m` (parser + builder)

**Interfaces:**
- Consumes: `ToolbarItemDef.items` (Task 1 added the field) — recursive `ToolbarItemDef[]`, one level.
- Produces: wire `{type:"group", id, controlRepresentation?, items:[<button wire>...]}`.

- [ ] **Step 1: Failing TS test**

Append to `runtime/toolbar.test.ts`:

```ts
describe("normalizeToolbar group (grouping)", () => {
  it("emits a group with nested button items + controlRepresentation", () => {
    const fn = () => {};
    const { json, actions } = normalizeToolbar({ items: [{
      type: "group", id: "nav", controlRepresentation: "collapsed",
      items: [{ id: "back", icon: "sf:chevron.left", action: fn }, { id: "fwd", icon: "sf:chevron.right" }],
    }] }, false, false);
    const it0 = JSON.parse(json).items[0];
    expect(it0.type).toBe("group");
    expect(it0.controlRepresentation).toBe("collapsed");
    expect(it0.items.map((x: any) => x.id)).toEqual(["back", "fwd"]);
    expect(actions.get("back")).toBe(fn);     // nested button actions register normally
  });
  it("rejects a group nested in a group", () => {
    expect(() => normalizeToolbar({ items: [{ type: "group", id: "g",
      items: [{ type: "group", id: "inner", items: [{ id: "x" }] } as any] }] }, false, false)).toThrow(/nest/i);
  });
});
```

- [ ] **Step 2: Run — expect FAIL**

Run: `cd /Users/zach/code/zapp && bun test runtime/toolbar.test.ts`
Expected: FAIL (group not handled).

- [ ] **Step 3: Handle "group" in normalizeToolbar**

In `runtime/window.ts` `normalizeToolbar`, add a `group` branch next to the `segmented` branch (before the `if (!item.id) …` line):

```ts
    if (type === "group") {
      if (!item.id) throw new Error('[zapp] toolbar: "group" items require an "id"');
      if (!item.items || item.items.length === 0) throw new Error('[zapp] toolbar: "group" requires a non-empty "items" array');
      if (seen.has(item.id)) throw new Error(`[zapp] toolbar: duplicate item id "${item.id}"`);
      seen.add(item.id);
      const wireItems: Record<string, unknown>[] = [];
      for (const sub of item.items) {
        if (sub.type === "group" || sub.type === "segmented") throw new Error('[zapp] toolbar: groups cannot nest groups');
        if (!sub.id) throw new Error('[zapp] toolbar: group sub-items require an "id"');
        if (sub.action) actions.set(sub.id, sub.action);
        const w: Record<string, unknown> = { type: "button", id: sub.id, label: sub.label ?? "", icon: sub.icon ?? "" };
        if (sub.enabled !== undefined) w.enabled = sub.enabled;
        if (sub.bordered !== undefined) w.bordered = sub.bordered;
        wireItems.push(w);
      }
      const g: Record<string, unknown> = { type: "group", id: item.id, items: wireItems };
      if (item.controlRepresentation !== undefined) g.controlRepresentation = item.controlRepresentation;
      items.push(g);
      continue;
    }
```

(Sub-items are buttons; their `action` registers in the same `actions` map keyed by `id` and fires via the existing `TOOLBAR_CLICKED` path — no new wiring. Menus/trio on sub-items are out of scope v1; keep sub-items to button basics.)

- [ ] **Step 4: Run TS tests — expect PASS**

Run: `cd /Users/zach/code/zapp && bun test runtime/toolbar.test.ts` → PASS.

- [ ] **Step 5: Nim group round-trip test (failing)**

In `native/nim/tests/windowmanager_test.nim` add:

```nim
test "plain group round-trips (grouping)":
  let t = ToolbarOptions(style: ToolbarStyle.Unified, items: @[
    ToolbarItemOpt(`type`: "group", id: "nav",
      controlRepresentation: ToolbarControlRepresentation.Collapsed,
      items: @[
        ToolbarItemOpt(`type`: "button", id: "back", icon: "sf:chevron.left", enabled: true, indicator: true, bordered: true),
        ToolbarItemOpt(`type`: "button", id: "fwd", icon: "sf:chevron.right", enabled: true, indicator: true, bordered: true)]),
  ])
  check parseToolbarJson(serializeToolbar(t)) == t
```

- [ ] **Step 6: Add `items` to ToolbarItemOpt + serialize/parse**

In `native/nim/window.nim`, add to `ToolbarItemOpt` (after the segmented fields from Task 2):

```nim
    items*: seq[ToolbarItemOpt]                  ## "group" sub-items (one level)
```

In `serializeToolbar`, add an `of "group":` arm (reuses the button serializer for each sub-item):

```nim
    of "group":
      var subs = newJArray()
      for sub in it.items:
        subs.add(%*{"type": "button", "id": sub.id, "label": sub.label,
                    "icon": sub.icon, "enabled": sub.enabled})
      var w = %*{"type": "group", "id": it.id, "items": subs}
      if it.controlRepresentation != ToolbarControlRepresentation.Automatic:
        w["controlRepresentation"] = %($it.controlRepresentation)
      items.add(w)
```

In `parseToolbarJson`, after the segmented handling add:

```nim
    if item.`type` == "group":
      item.controlRepresentation = (if jHasStr(itn, "controlRepresentation"):
        enumFromStr[ToolbarControlRepresentation](jStr(itn, "controlRepresentation"), ToolbarControlRepresentation.Automatic)
        else: ToolbarControlRepresentation.Automatic)
      let subn = itn{"items"}
      if not subn.isNil and subn.kind == JArray:
        for sn in subn:
          if sn.kind != JObject: continue
          var sub = ToolbarItemOpt(`type`: "button", enabled: true, indicator: true, bordered: true)
          if jHasStr(sn, "id"): sub.id = jStr(sn, "id")
          if jHasStr(sn, "label"): sub.label = jStr(sn, "label")
          if jHasStr(sn, "icon"): sub.icon = jStr(sn, "icon")
          if jHasBool(sn, "enabled"): sub.enabled = jBool(sn, "enabled", true)
          item.items.add(sub)
```

- [ ] **Step 7: Run Nim test — expect PASS**

Run: `cd /Users/zach/code/zapp && nim c -r --hints:off native/nim/tests/windowmanager_test.nim` → PASS.

- [ ] **Step 8: Native — build the subitems group**

In `native/platform/darwin/toolbar.m`: in `zapp_toolbar_parse_items` add a `"group"` arm mirroring the `"segmented"` arm (Step 2 of Task 3) — store `buttons[gid] = def`. In the builder, add a `group` branch next to the segmented one:

```objc
    if ([def[@"type"] isEqualToString:@"group"]) {
        if (@available(macOS 10.15, *)) {
            NSToolbarItemGroup* group = [[NSToolbarItemGroup alloc] initWithItemIdentifier:identifier];
            NSArray* subs = [def[@"items"] isKindOfClass:[NSArray class]] ? def[@"items"] : @[];
            NSMutableArray<NSToolbarItem*>* built = [NSMutableArray array];
            for (NSDictionary* sub in subs) {
                NSString* sid = [sub[@"id"] isKindOfClass:[NSString class]] ? sub[@"id"] : nil;
                if (!sid.length) continue;
                NSToolbarItem* bi = [[NSToolbarItem alloc] initWithItemIdentifier:sid];
                NSString* lbl = [sub[@"label"] isKindOfClass:[NSString class]] ? sub[@"label"] : @"";
                bi.label = lbl; bi.paletteLabel = lbl.length ? lbl : sid; bi.toolTip = lbl;
                NSString* ic = [sub[@"icon"] isKindOfClass:[NSString class]] ? sub[@"icon"] : @"";
                if (ic.length) bi.image = zapp_resolve_icon(ic, 18.0, 1);
                bi.target = self; bi.action = @selector(zappToolbarItemClicked:);
                zapp_toolbar_apply_trio(bi, sub);   // bordered (+ macOS-26 trio if present)
                [built addObject:bi];
            }
            group.subitems = built;
            NSString* repr = [def[@"controlRepresentation"] isKindOfClass:[NSString class]] ? def[@"controlRepresentation"] : @"automatic";
            group.controlRepresentation = [repr isEqualToString:@"expanded"] ? NSToolbarItemGroupControlRepresentationExpanded
                : ([repr isEqualToString:@"collapsed"] ? NSToolbarItemGroupControlRepresentationCollapsed : NSToolbarItemGroupControlRepresentationAutomatic);
            return group;
        }
        NSLog(@"[zapp] toolbar: group requires macOS 10.15 — item dropped");
        return nil;
    }
```

(Sub-item clicks use the existing `zappToolbarItemClicked:` → `zapp_toolbar_emit_click` → `TOOLBAR_CLICKED`, so the `actions` registered by id in Step 3 fire with zero new plumbing.)

- [ ] **Step 9: Build macOS + iOS + commit**

Run both builds (expect `[zapp] build complete:`), then:
```bash
cd /Users/zach/code/zapp
git add runtime/window.ts runtime/toolbar.test.ts native/nim/window.nim native/nim/tests/windowmanager_test.nim native/platform/darwin/toolbar.m
git commit -m "$(cat <<'EOF'
feat(toolbar): plain "group" flavor (NSToolbarItemGroup subitems)

type:"group" clusters full button sub-items (one level, no nested groups) with
controlRepresentation for overflow-collapse; sub-item clicks reuse the existing
TOOLBAR_CLICKED path. TS+Nim parity + native subitems builder.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Showcase + docs + gates + human visual smoke

**Files:**
- Modify: `kitchen-sink/src/shell/toolbar-def.ts`, `kitchen-sink/src/sections/toolbar.ts`
- Modify: `docs/api-reference.md`, `docs/native-ui-strategy.md`

- [ ] **Step 1: Showcase — segmented view-switcher + momentary group + cluster**

In `kitchen-sink/src/shell/toolbar-def.ts`, add to `shellToolbar()` (before `flexibleSpace`): a `selectOne` view-switcher and a `momentary` format group:

```ts
    { type: "segmented", id: "view", selectionMode: "one", selected: 0,
      segments: [
        { id: "grid", icon: "sf:square.grid.2x2", action: () => Events.emit("ks:toolbar", { id: "view:grid" }) },
        { id: "list", icon: "sf:list.bullet",     action: () => Events.emit("ks:toolbar", { id: "view:list" }) },
      ] },
    { type: "segmented", id: "fmt", selectionMode: "momentary",
      segments: [
        { id: "bold",   icon: "sf:bold",      action: () => Events.emit("ks:toolbar", { id: "fmt:bold" }) },
        { id: "italic", icon: "sf:italic",    action: () => Events.emit("ks:toolbar", { id: "fmt:italic" }) },
      ] },
```

In `kitchen-sink/src/sections/toolbar.ts`, in the `inspector(host)` (or render) add a `win.on(WindowEvent.TOOLBAR_GROUP_SELECTED, …)` subscription that shows `{id, index, selected}`, demonstrating the public event.

- [ ] **Step 2: Build + verify the showcase compiles**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run build` → `[zapp] build complete:`.

- [ ] **Step 3: Docs**

In `docs/api-reference.md` (toolbar section) document `type: "segmented"` (segments, selectionMode one/any/momentary, selected, controlRepresentation, the per-segment `action`, `TOOLBAR_GROUP_SELECTED` event + `updateItem({selected})`) and `type: "group"` (items, controlRepresentation overflow-collapse). Note macOS 10.15 floor.

In `docs/native-ui-strategy.md` add a short "Toolbar grouping" note under the toolbar sections: the two NSToolbarItemGroup flavors, the shared `action: () => void` primitive, and that selection uses `TOOLBAR_GROUP_SELECTED` (with the menu-like unification still a follow-up). Add a roadmap row.

- [ ] **Step 4: Full build matrix**

Run:
```bash
cd /Users/zach/code/zapp && bun test runtime cli/src 2>&1 | tail -3
cd /Users/zach/code/zapp/kitchen-sink && bun run build 2>&1 | tail -1
cd /Users/zach/code/zapp/kitchen-sink && bun run build --platform ios 2>&1 | tail -1
```
Expected: bun `0 fail`; both builds `[zapp] build complete:`.

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add kitchen-sink/src/shell/toolbar-def.ts kitchen-sink/src/sections/toolbar.ts docs/api-reference.md docs/native-ui-strategy.md
git commit -m "$(cat <<'EOF'
demo+docs(toolbar): grouping showcase + api docs

Kitchen-sink: selectOne view-switcher + momentary format segmented groups with
TOOLBAR_GROUP_SELECTED display. Document type:"segmented" + type:"group".

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 6: HUMAN VISUAL GATE**

Hand off: `cd /Users/zach/code/zapp/kitchen-sink && bun run dev`. Ask the user to confirm:
1. The **view** segmented control shows two segments; clicking one selects it (selectOne highlight) and updates the section state via `TOOLBAR_GROUP_SELECTED`.
2. The **fmt** momentary group fires per-segment actions (no persistent highlight).
3. (If a `group` cluster was added) it clusters + collapses to an overflow menu when the window narrows.
4. Existing toolbar behaviors (compose prominent, inbox badge, filter, remove/attach) still work.

GO → grouping done. Issues → fix and re-smoke. (Watch specifically for the **momentary index** resolving correctly — if a momentary segment's action doesn't fire, that's the `selectedIndex == -1` case from Task 3 Step 4; switch to reading the sender's `NSSegmentedControl.selectedSegment`.)

---

## Self-review notes

- **Spec coverage:** segmented (T1 TS + T2 Nim + T3 native), event (T1 events.ts + T3 emit), selection + updateItem (T1/T3), plain group (T4), showcase+docs (T5), gating macOS 10.15 (T3/T4 `@available`), parity (T1↔T2, T4 both sides), no nested groups (T4 reject). All mapped.
- **Naming consistency:** wire keys `type:"segmented"|"group"`, `segments`, `selectionMode` ("one"/"any"/"momentary"), `selected` (array), `controlRepresentation` ("automatic"/"expanded"/"collapsed") identical across T1 (TS emit), T2/T4 (Nim emit+parse), T3/T4 (native read). `TOOLBAR_GROUP_SELECTED`/`window:toolbar-group-selected` consistent T1↔T3. Segment action key `groupId:index` (T1) ↔ event index (T3). `zapp_toolbar_emit_group_select(host,id,index,selected)` consistent T3.
- **Open native detail flagged, not placeholdered:** momentary `selectedIndex == -1` has a concrete fallback (isSelectedAtIndex loop; else NSSegmentedControl.selectedSegment) + a T5 smoke check.
