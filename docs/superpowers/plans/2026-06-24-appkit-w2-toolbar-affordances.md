# AppKit W2 — Toolbar Affordances Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-item macOS-26 toolbar styling — prominent style + tint, badge, and non-bordered — to Zapp's toolbar API, live-updatable, with TS↔Nim parity and silent <macOS-26 fallback.

**Architecture:** Four additive fields (`style`, `tintColor`, `badge`, `bordered`) flow as wire-JSON keys: TS `ToolbarItemDef`/`ToolbarItemPatch` (`normalizeToolbar`/`normalizeToolbarPatch`) and Nim `ToolbarItemOpt` (`serializeToolbar`/`parseToolbarJson`) both emit them; `toolbar.m` already stores each item's full def, so the item builder and `updateItem` mutate-path just read and apply the new keys onto the `NSToolbarItem`. No new C-ABI symbols, router arms, or iOS stubs.

**Tech Stack:** TypeScript (Bun test), Nim (`std/json`, `unittest`), Objective-C (AppKit `NSToolbarItem`/`NSItemBadge`, macOS 26 SDK), Zapp CLI build.

## Global Constraints

- Branch `feat/nim-native`; do NOT merge or switch branches.
- Commit trailer on every commit: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- Commit/push only as this plan directs (commit per task; do not push).
- **Staging discipline: explicit per-file `git add` only. NEVER `git add -A` / `git add .`** — the tree has unrelated pre-existing WIP under `assets/`, `benchmarks/`, `vendor/`, `spikes/`, plus untracked files. Stage only the files each task names.
- Always use Bun, never Node.
- macOS-26 affordances (`style`/`tintColor`/`badge`) are gated `if (@available(macOS 26.0, *))` and silently no-op below; `bordered` (macOS 10.15) is ungated.
- "macOS build success" = the CLI prints `[zapp] build complete: …` as the LAST line (Vite's `✓ built` is NOT success).
- T1 and T5 end in **human visual smoke gates** — pause and hand off to the user; do not self-certify them.

## Wire JSON contract (shared by TS + Nim, parsed in toolbar.m)

Per custom-button item, all keys optional (absence ⇒ native default):

```json
{ "id": "compose",
  "style": "prominent",            // "plain" | "prominent"   (omit ⇒ plain)
  "tintColor": "#aa3bff",          // hex; only meaningful when prominent
  "bordered": false,               // omit ⇒ true
  "badge": { "kind": "count", "count": 3 } }
```

`badge.kind` ∈ `"count" | "text" | "dot" | "none"`. `count` carries an int; `text` carries a string; `dot`/`none` carry nothing. On a **patch**, `{"kind":"none"}` clears the badge.

---

## Task 1: RISK GATE — prove prominent + badge render (human visual)

Confirm `NSToolbarItemStyleProminent` + `NSItemBadge` actually render on Zapp's standard `NSToolbarItem`s before building the full surface. Hardcode on one kitchen-sink item, smoke, then revert the hardcode.

**Files:**
- Modify (temporary): `native/platform/darwin/toolbar.m` (item builder, the custom-button branch ~line 222–238)

- [ ] **Step 1: Hardcode prominent + badge on the `compose` button**

In `toolbar.m`, in `toolbar:itemForItemIdentifier:`, inside the final custom-button branch (after `item.action = @selector(zappToolbarItemClicked:);`, around line 234), add a temporary block:

```objc
    // W2 T1 RISK GATE (temporary — revert after smoke)
    if ([identifier isEqualToString:@"compose"]) {
        if (@available(macOS 26.0, *)) {
            item.style = NSToolbarItemStyleProminent;
            item.backgroundTintColor = [NSColor systemPurpleColor];
            item.badge = [NSItemBadge badgeWithCount:3];
        }
    }
```

- [ ] **Step 2: Build the kitchen-sink**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run build`
Expected: last line `[zapp] build complete: …/bin/kitchen-sink (… KB)` (fresh mtime).

- [ ] **Step 3: HUMAN VISUAL GATE**

Hand off to the user: `cd /Users/zach/code/zapp/kitchen-sink && bun run dev`. Ask them to confirm the **Compose** toolbar button renders with a purple prominent (tinted) background and a "3" badge. GO → continue. NO-GO (renders plain / crashes) → STOP and report; the affordance may need a view-backed item — revisit the design.

- [ ] **Step 4: Revert the hardcode**

Remove the temporary block from Step 1. Verify nothing of it remains:
Run: `rg -n "W2 T1 RISK GATE" native/platform/darwin/toolbar.m` → expect no output.

- [ ] **Step 5: Rebuild to confirm clean revert**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run build`
Expected: `[zapp] build complete: …`. No commit (this task leaves no diff).

---

## Task 2: TS — ToolbarItemDef/ToolbarItemPatch fields + normalize (TDD)

**Files:**
- Modify: `runtime/window.ts` (`ToolbarItemDef` ~328, `ToolbarItemPatch` ~370, `normalizeToolbar` ~583, `TOOLBAR_PATCH_KEYS` ~660, `normalizeToolbarPatch` ~665)
- Test: `runtime/toolbar.test.ts`

**Interfaces:**
- Produces (wire JSON keys consumed by Task 3 Nim parity + Task 4 native): per item `style: "plain"|"prominent"`, `tintColor: string`, `bordered: boolean`, `badge: {kind:"count",count}|{kind:"text",text}|{kind:"dot"}|{kind:"none"}`.
- Consumes: nothing new.

- [ ] **Step 1: Write failing tests**

Append to `runtime/toolbar.test.ts` (use the real exported names `normalizeToolbar` / `normalizeToolbarPatch` — they're already imported at the top of the file):

```ts
describe("normalizeToolbar trio (W2)", () => {
  it("emits style, tintColor, bordered, and tagged badge", () => {
    const { json } = normalizeToolbar({
      items: [{ id: "go", label: "Go", style: "prominent", tintColor: "#aa3bff",
                bordered: false, badge: { count: 3 } }],
    }, false, false);
    const item = JSON.parse(json).items[0];
    expect(item.style).toBe("prominent");
    expect(item.tintColor).toBe("#aa3bff");
    expect(item.bordered).toBe(false);
    expect(item.badge).toEqual({ kind: "count", count: 3 });
  });
  it("maps badge variants (text, dot)", () => {
    const text = JSON.parse(normalizeToolbar({ items: [{ id: "a", badge: { text: "NEW" } }] }, false, false).json).items[0];
    expect(text.badge).toEqual({ kind: "text", text: "NEW" });
    const dot = JSON.parse(normalizeToolbar({ items: [{ id: "b", badge: { dot: true } }] }, false, false).json).items[0];
    expect(dot.badge).toEqual({ kind: "dot" });
  });
  it("omits trio keys when unset", () => {
    const item = JSON.parse(normalizeToolbar({ items: [{ id: "x" }] }, false, false).json).items[0];
    expect(item.style).toBeUndefined();
    expect(item.tintColor).toBeUndefined();
    expect(item.bordered).toBeUndefined();
    expect(item.badge).toBeUndefined();
  });
});

describe("normalizeToolbarPatch trio (W2)", () => {
  it("emits trio keys and clears badge with null", () => {
    const set = JSON.parse(normalizeToolbarPatch("compose", { style: "prominent", tintColor: "#fff", bordered: true, badge: { count: 5 } }).json);
    expect(set.style).toBe("prominent");
    expect(set.tintColor).toBe("#fff");
    expect(set.bordered).toBe(true);
    expect(set.badge).toEqual({ kind: "count", count: 5 });
    const cleared = JSON.parse(normalizeToolbarPatch("compose", { badge: null }).json);
    expect(cleared.badge).toEqual({ kind: "none" });
  });
});
```

- [ ] **Step 2: Run tests — expect FAIL**

Run: `cd /Users/zach/code/zapp && bun test runtime/toolbar.test.ts`
Expected: FAIL (the new fields aren't emitted; `item.style` etc. are undefined).

- [ ] **Step 3: Add the fields to the interfaces**

In `runtime/window.ts`, inside `interface ToolbarItemDef` (after the `indicator?` field, ~line 358):

```ts
  /** macOS 26+. "prominent" tints the item background (the new-design
   *  highlighted action). Default "plain". No-op < macOS 26. */
  style?: "plain" | "prominent";
  /** macOS 26+. Hex color tinting a prominent item's background; ignored
   *  unless `style` is "prominent". Omit → system accent. No-op < macOS 26. */
  tintColor?: string;
  /** macOS 26+. A badge: a count, short text, or a plain dot. No-op < macOS 26. */
  badge?: { count: number } | { text: string } | { dot: true };
  /** Draw the item's standard bordered background. Default true; false → flat.
   *  All macOS versions. */
  bordered?: boolean;
```

In `interface ToolbarItemPatch` (after the `action?` field, ~line 381):

```ts
  style?: "plain" | "prominent";
  tintColor?: string;
  /** Pass null to clear the badge. */
  badge?: { count: number } | { text: string } | { dot: true } | null;
  bordered?: boolean;
```

- [ ] **Step 4: Add the badge→wire helper + emit in normalizeToolbar**

In `runtime/window.ts`, just above `export function normalizeToolbar(` (~line 583), add:

```ts
/** Convert a ToolbarItemDef/Patch badge value to its tagged wire form.
 *  null (patch-only) → clear. */
function badgeToWire(
  b: { count: number } | { text: string } | { dot: true } | null,
): Record<string, unknown> {
  if (b === null) return { kind: "none" };
  if ("count" in b) return { kind: "count", count: b.count };
  if ("text" in b) return { kind: "text", text: b.text };
  return { kind: "dot" };
}
```

In `normalizeToolbar`, in the custom-button branch where `wire` is built (after the `if (item.indicator !== undefined) wire.indicator = item.indicator;` line, ~648):

```ts
    if (item.style !== undefined) wire.style = item.style;
    if (item.tintColor !== undefined) wire.tintColor = item.tintColor;
    if (item.bordered !== undefined) wire.bordered = item.bordered;
    if (item.badge !== undefined) wire.badge = badgeToWire(item.badge);
```

- [ ] **Step 5: Extend the patch key allowlist + emit in normalizeToolbarPatch**

In `runtime/window.ts`, update `TOOLBAR_PATCH_KEYS` (~660):

```ts
const TOOLBAR_PATCH_KEYS = new Set(["label", "icon", "enabled", "indicator", "menu", "action", "style", "tintColor", "badge", "bordered"]);
```

In `normalizeToolbarPatch`, after `if (patch.indicator !== undefined) wire.indicator = patch.indicator;` (~692):

```ts
  if (patch.style !== undefined) wire.style = patch.style;
  if (patch.tintColor !== undefined) wire.tintColor = patch.tintColor;
  if (patch.bordered !== undefined) wire.bordered = patch.bordered;
  if (patch.badge !== undefined) wire.badge = badgeToWire(patch.badge);
```

(The existing empty-patch guard at the end already accepts these — `wire` now has >1 key when any trio field is set.)

- [ ] **Step 6: Run tests — expect PASS**

Run: `cd /Users/zach/code/zapp && bun test runtime/toolbar.test.ts`
Expected: PASS (all suites, including the pre-existing ones).

- [ ] **Step 7: Type-check**

Run: `cd /Users/zach/code/zapp && bunx tsc --noEmit -p tsconfig.json` (or `bun run check` if defined)
Expected: no NEW errors referencing `window.ts` toolbar types (the repo has a known small baseline — compare against it; introduce none).

- [ ] **Step 8: Commit**

```bash
cd /Users/zach/code/zapp
git add runtime/window.ts runtime/toolbar.test.ts
git commit -m "$(cat <<'EOF'
feat(toolbar): TS style/tintColor/badge/bordered fields + normalize (W2)

Add the macOS-26 per-item styling trio to ToolbarItemDef + ToolbarItemPatch,
emitted as wire-JSON keys (tagged badge: {kind,count|text}). badge:null clears.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Nim — ToolbarItemOpt fields + serialize/parse parity (TDD)

**Files:**
- Modify: `native/nim/window.nim` (enums + `ToolbarItemOpt` ~75, `serializeToolbar` ~382, `parseToolbarJson` ~405)
- Test: `native/nim/tests/windowmanager_test.nim`

**Interfaces:**
- Consumes: the wire JSON keys defined in Task 2 (`style`, `tintColor`, `bordered`, tagged `badge`).
- Produces: `serializeToolbar(t)` emits those keys; `parseToolbarJson` round-trips them (`parseToolbarJson(serializeToolbar(t)) == t`).

- [ ] **Step 1: Write the failing round-trip test**

In `native/nim/tests/windowmanager_test.nim`, find the existing toolbar round-trip block (it builds a `ToolbarOptions`, asserts `parseToolbarJson(serializeToolbar(t)) == t`). Add a new test that includes the trio (place it near the existing toolbar test):

```nim
test "toolbar trio fields round-trip (W2)":
  let t = ToolbarOptions(style: ToolbarStyle.Unified, items: @[
    ToolbarItemOpt(`type`: "button", id: "go", label: "Go", enabled: true,
      indicator: true, bordered: false,
      style: ToolbarItemStyle.Prominent, tintColor: "#aa3bff",
      badge: ToolbarBadge(kind: ToolbarBadgeKind.Count, count: 3)),
    ToolbarItemOpt(`type`: "button", id: "tag", label: "Tag", enabled: true,
      indicator: true, bordered: true,
      badge: ToolbarBadge(kind: ToolbarBadgeKind.Dot)),
  ])
  let s = serializeToolbar(t)
  check parseToolbarJson(s) == t
  # spot-check the wire keys native parses
  let root = parseJson(s)
  check root["items"][0]["style"].getStr == "prominent"
  check root["items"][0]["tintColor"].getStr == "#aa3bff"
  check root["items"][0]["bordered"].getBool == false
  check root["items"][0]["badge"]["kind"].getStr == "count"
  check root["items"][0]["badge"]["count"].getInt == 3
  check root["items"][1]["badge"]["kind"].getStr == "dot"
```

- [ ] **Step 2: Run the test — expect FAIL (compile error: unknown fields/enums)**

Run: `cd /Users/zach/code/zapp && nim c -r --hints:off native/nim/tests/windowmanager_test.nim`
Expected: FAIL — `ToolbarItemStyle`/`ToolbarBadge` undeclared, `ToolbarItemOpt` has no `bordered`/`style`/`badge`.

- [ ] **Step 3: Add the enums + types**

In `native/nim/window.nim`, in the `type` block just above `ToolbarItemOpt` (~line 71, near `MenuItemOpt`):

```nim
  ToolbarItemStyle* {.pure.} = enum     ## NSToolbarItemStyle (macOS 26)
    Plain = "plain"
    Prominent = "prominent"

  ToolbarBadgeKind* {.pure.} = enum     ## NSItemBadge variant (macOS 26)
    None = "none", Count = "count", Text = "text", Dot = "dot"

  ToolbarBadge* = object                ## mirrors TS badge union
    kind*: ToolbarBadgeKind             ## None ⇒ no badge / clear
    count*: int
    text*: string
```

Extend `ToolbarItemOpt` (after the `menu*` field, ~line 82):

```nim
    style*: ToolbarItemStyle            ## default Plain; macOS 26+
    tintColor*: string                  ## hex; emitted only when Prominent
    badge*: ToolbarBadge                ## kind None ⇒ omitted
    bordered*: bool = true
```

- [ ] **Step 4: Emit the keys in serializeToolbar**

In `serializeToolbar` (~382), in the `else: # button (default)` branch, after `w` is built and before the `if it.menu.len > 0:` block (i.e. right after line 393 `"icon": it.icon, "enabled": it.enabled}`), add:

```nim
      if it.style == ToolbarItemStyle.Prominent: w["style"] = %($it.style)
      if it.tintColor.len > 0: w["tintColor"] = %it.tintColor
      if not it.bordered: w["bordered"] = %false
      case it.badge.kind
      of ToolbarBadgeKind.Count: w["badge"] = %*{"kind": "count", "count": it.badge.count}
      of ToolbarBadgeKind.Text:  w["badge"] = %*{"kind": "text", "text": it.badge.text}
      of ToolbarBadgeKind.Dot:   w["badge"] = %*{"kind": "dot"}
      of ToolbarBadgeKind.None:  discard
```

- [ ] **Step 5: Parse the keys back in parseToolbarJson**

In `parseToolbarJson` (~405), in the per-item loop after `if jHasBool(itn, "indicator"): item.indicator = jBool(itn, "indicator", true)` (~422), add:

```nim
    if jHasStr(itn, "style"): item.style = enumFromStr[ToolbarItemStyle](jStr(itn, "style"), ToolbarItemStyle.Plain)
    if jHasStr(itn, "tintColor"): item.tintColor = jStr(itn, "tintColor")
    item.bordered = (if jHasBool(itn, "bordered"): jBool(itn, "bordered", true) else: true)
    let bn = itn{"badge"}
    if not bn.isNil and bn.kind == JObject:
      let bk = if jHasStr(bn, "kind"): jStr(bn, "kind") else: "none"
      case bk
      of "count": item.badge = ToolbarBadge(kind: ToolbarBadgeKind.Count, count: (if jHasInt(bn, "count"): jInt(bn, "count", 0) else: 0))
      of "text":  item.badge = ToolbarBadge(kind: ToolbarBadgeKind.Text, text: (if jHasStr(bn, "text"): jStr(bn, "text") else: ""))
      of "dot":   item.badge = ToolbarBadge(kind: ToolbarBadgeKind.Dot)
      else:       item.badge = ToolbarBadge(kind: ToolbarBadgeKind.None)
```

Note: `ToolbarItemOpt` constructed at ~415 is `ToolbarItemOpt(enabled: true, indicator: true)`; `bordered` defaults to `true` via the field default, and the explicit assignment above also covers it — keep the explicit line so the round-trip is unambiguous. If `jHasInt`/`jInt` helpers don't exist in `window.nim`, add them mirroring the existing `jHasBool`/`jBool` (search for `proc jBool` and add an int twin directly above/below it):

```nim
proc jHasInt(a: JsonNode, k: string): bool =
  let v = a{k}; (not v.isNil and v.kind == JInt)
proc jInt(a: JsonNode, k: string, d: int): int =
  let v = a{k}; (if v.isNil or v.kind != JInt: d else: v.getInt)
```

- [ ] **Step 6: Run the test — expect PASS**

Run: `cd /Users/zach/code/zapp && nim c -r --hints:off native/nim/tests/windowmanager_test.nim`
Expected: PASS (the new test + all pre-existing ones, including the original toolbar round-trip).

- [ ] **Step 7: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/window.nim native/nim/tests/windowmanager_test.nim
git commit -m "$(cat <<'EOF'
feat(toolbar): Nim ToolbarItemOpt style/tintColor/badge/bordered parity (W2)

ToolbarItemStyle + ToolbarBadge(kind/count/text) on ToolbarItemOpt;
serializeToolbar emits + parseToolbarJson round-trips the trio, matching the
TS wire schema.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Native — toolbar.m applies the trio (builder + updateItem)

**Files:**
- Modify: `native/platform/darwin/toolbar.m` (helpers near top; item builder ~140–238; `darwin_toolbar_update_item` ~433–519)

**Interfaces:**
- Consumes: the per-item def dict stored in `self.buttonsById[id]` (already carries the new keys verbatim — `zapp_toolbar_parse_items` stores the whole def). Wire keys: `style`, `tintColor`, `bordered`, `badge:{kind,count|text}`.
- Produces: rendered/mutated `NSToolbarItem` styling. No new exported symbols.

- [ ] **Step 1: Add the color + badge helpers**

In `native/platform/darwin/toolbar.m`, after the existing `static NSString* const kZapp…` constants (near line 36), add two static helpers:

```objc
// Parse "#RGB" / "#RRGGBB" / "#RRGGBBAA" → NSColor (nil on malformed).
static NSColor* zapp_toolbar_color(NSString* hex) {
    if (![hex isKindOfClass:[NSString class]] || hex.length == 0) return nil;
    NSString* s = [hex hasPrefix:@"#"] ? [hex substringFromIndex:1] : hex;
    if (s.length == 3) { // expand #RGB → #RRGGBB
        unichar c[3]; [s getCharacters:c range:NSMakeRange(0,3)];
        s = [NSString stringWithFormat:@"%C%C%C%C%C%C", c[0],c[0],c[1],c[1],c[2],c[2]];
    }
    if (s.length != 6 && s.length != 8) return nil;
    unsigned int v = 0;
    if (![[NSScanner scannerWithString:s] scanHexInt:&v]) return nil;
    CGFloat r,g,b,a;
    if (s.length == 8) { r=((v>>24)&0xFF)/255.0; g=((v>>16)&0xFF)/255.0; b=((v>>8)&0xFF)/255.0; a=(v&0xFF)/255.0; }
    else               { r=((v>>16)&0xFF)/255.0; g=((v>>8)&0xFF)/255.0; b=(v&0xFF)/255.0; a=1.0; }
    return [NSColor colorWithSRGBRed:r green:g blue:b alpha:a];
}

// Build an NSItemBadge from a def's "badge" dict. Returns nil for absent/none.
API_AVAILABLE(macos(26.0))
static NSItemBadge* zapp_toolbar_badge(NSDictionary* def) {
    NSDictionary* b = [def[@"badge"] isKindOfClass:[NSDictionary class]] ? def[@"badge"] : nil;
    if (!b) return nil;
    NSString* kind = [b[@"kind"] isKindOfClass:[NSString class]] ? b[@"kind"] : @"none";
    if ([kind isEqualToString:@"count"]) {
        NSNumber* n = [b[@"count"] isKindOfClass:[NSNumber class]] ? b[@"count"] : @0;
        return [NSItemBadge badgeWithCount:n.integerValue];
    }
    if ([kind isEqualToString:@"text"]) {
        NSString* t = [b[@"text"] isKindOfClass:[NSString class]] ? b[@"text"] : @"";
        return [NSItemBadge badgeWithText:t];
    }
    if ([kind isEqualToString:@"dot"]) return [NSItemBadge indicatorBadge];
    return nil; // "none"
}
```

Add a shared applier (also static, below the helpers) that both the builder and the patch path call:

```objc
// Apply the W2 trio (style/tint/badge/bordered) from a stored def onto a live
// item. bordered is ungated; style/tint/badge require macOS 26.
static void zapp_toolbar_apply_trio(NSToolbarItem* item, NSDictionary* def) {
    NSNumber* bordered = [def[@"bordered"] isKindOfClass:[NSNumber class]] ? def[@"bordered"] : nil;
    if (@available(macOS 10.15, *)) item.bordered = bordered ? bordered.boolValue : YES;
    if (@available(macOS 26.0, *)) {
        NSString* style = [def[@"style"] isKindOfClass:[NSString class]] ? def[@"style"] : @"plain";
        BOOL prominent = [style isEqualToString:@"prominent"];
        item.style = prominent ? NSToolbarItemStyleProminent : NSToolbarItemStylePlain;
        NSString* tint = [def[@"tintColor"] isKindOfClass:[NSString class]] ? def[@"tintColor"] : nil;
        item.backgroundTintColor = prominent ? zapp_toolbar_color(tint) : nil;
        item.badge = zapp_toolbar_badge(def);
    }
}
```

- [ ] **Step 2: Call the applier in the item builder (both button shapes)**

In `toolbar:itemForItemIdentifier:`, the menu-item branch (`NSMenuToolbarItem`): just before `return mitem;` (~line 217) add:

```objc
            zapp_toolbar_apply_trio(mitem, def);
```

The plain-button branch: replace the existing bordered block (lines ~235–237):

```objc
    if (@available(macOS 10.15, *)) {
        item.bordered = YES; // modern pill-button look in unified styles
    }
```

with:

```objc
    zapp_toolbar_apply_trio(item, def);
```

(The applier sets `bordered` to the def value or YES default — preserving the old behavior when `bordered` is unset.)

- [ ] **Step 3: Apply the trio in updateItem (live mutate)**

In `darwin_toolbar_update_item`, after the menu/icon/`if (@available(macOS 10.15, *)) { if (isMenuItem) {…} }` block and before `[window.toolbar validateVisibleItems];` (~line 516), add — applying from the **merged** def so unspecified keys keep their current value:

```objc
        // W2 trio: re-apply from the merged def (covers style/tint/badge/bordered;
        // badge {"kind":"none"} → cleared). Works for both button + menu items.
        if (patch[@"style"] || patch[@"tintColor"] || patch[@"bordered"] || patch[@"badge"]) {
            zapp_toolbar_apply_trio(live, merged);
        }
```

- [ ] **Step 4: Build the kitchen-sink (macOS)**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run build`
Expected: last line `[zapp] build complete: …/bin/kitchen-sink (… KB)`.

- [ ] **Step 5: Build iOS-sim (no regression)**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run build --platform ios`
Expected: `[zapp] build complete: …/bin/ios/…`. (toolbar.m is darwin-macOS; confirm the shared build stays green.)

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add native/platform/darwin/toolbar.m
git commit -m "$(cat <<'EOF'
feat(macos): apply toolbar style/tint/badge/bordered (W2)

zapp_toolbar_apply_trio reads the per-item def and sets NSToolbarItem.style +
backgroundTintColor + badge (macOS 26) and bordered (10.15) in the item builder
and updateItem mutate-path. Hex→NSColor + NSItemBadge helpers added.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Showcase + docs + gates + human visual smoke

**Files:**
- Modify: `kitchen-sink/src/shell/toolbar-def.ts` (shell toolbar), `kitchen-sink/src/sections/toolbar.ts` (section controls)
- Modify: `docs/api-reference.md` (toolbar section), `docs/native-ui-strategy.md` (W2 note)

**Interfaces:**
- Consumes: the runtime `ToolbarItemDef`/`ToolbarItemPatch` trio fields (Task 2) via `win.toolbar.setItems` / `updateItem`.

- [ ] **Step 1: Add trio affordances to the shell toolbar**

In `kitchen-sink/src/shell/toolbar-def.ts`, in `shellToolbar()`, make `compose` prominent + add a borderless item and a badged item. Replace the `compose` entry and add a new item before `flexibleSpace`:

```ts
    { id: "compose", icon: "sf:square.and.pencil", label: "Compose",
      style: "prominent", tintColor: "#aa3bff",
      action: () => Events.emit("ks:toolbar", { id: "compose" }) },
    { id: "inbox", icon: "sf:tray", label: "Inbox", bordered: false,
      badge: { count: 0 },
      action: () => Events.emit("ks:toolbar", { id: "inbox" }) },
```

(Place `inbox` right after `compose`. Leave the rest of the toolbar unchanged.)

- [ ] **Step 2: Add live badge increment/clear controls to the Toolbar section**

In `kitchen-sink/src/sections/toolbar.ts`, add two buttons to the `card({ … buttons: [...] })` array:

```ts
        { act: "badge-inc", label: "Inbox badge +1" },
        { act: "badge-clear", label: "Clear inbox badge" },
```

And add the handlers (alongside the existing `onAct` blocks), tracking a module-level count near `let composeEnabled = true;`:

```ts
let inboxCount = 0;
```

```ts
    onAct(host, "badge-inc", () => {
      inboxCount += 1;
      win.toolbar.updateItem("inbox", { badge: { count: inboxCount } });
      setResult(host, `inbox badge → ${inboxCount}`);
    });
    onAct(host, "badge-clear", () => {
      inboxCount = 0;
      win.toolbar.updateItem("inbox", { badge: null });
      setResult(host, "inbox badge cleared");
    });
```

- [ ] **Step 3: Build the kitchen-sink**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run build`
Expected: `[zapp] build complete: …`.

- [ ] **Step 4: Document the API**

In `docs/api-reference.md`, in the toolbar section (search "ToolbarItemDef"), add a subsection documenting `style` ("plain"|"prominent"), `tintColor` (hex; prominent only; omit → accent), `badge` (`{count}`/`{text}`/`{dot}`; patch `null` clears), and `bordered` (default true). State the macOS-26 gate + silent fallback for style/tint/badge; `bordered` is universal. Note all four are also `updateItem`-patchable (live badges). Match the existing doc style.

In `docs/native-ui-strategy.md`, add a short "Toolbar affordances (macOS 26)" note under the new-design section: the trio recovers the prominent/badge/flat looks natively via `ToolbarItemDef`, macOS-26-gated, parity across TS + Nim authoring. Link the spec `docs/superpowers/specs/2026-06-24-appkit-w2-toolbar-affordances-design.md`.

- [ ] **Step 5: Verify docs**

Run: `cd /Users/zach/code/zapp && rg -n "tintColor|badge|prominent" docs/api-reference.md docs/native-ui-strategy.md | head`
Expected: shows the new content in both files.

- [ ] **Step 6: Full build matrix**

Run:
```bash
cd /Users/zach/code/zapp && bun test runtime cli/src 2>&1 | tail -3
cd /Users/zach/code/zapp/kitchen-sink && bun run build 2>&1 | tail -1
cd /Users/zach/code/zapp/kitchen-sink && bun run build --platform ios 2>&1 | tail -1
```
Expected: bun tests `0 fail`; both builds `[zapp] build complete: …`.

- [ ] **Step 7: Commit**

```bash
cd /Users/zach/code/zapp
git add kitchen-sink/src/shell/toolbar-def.ts kitchen-sink/src/sections/toolbar.ts docs/api-reference.md docs/native-ui-strategy.md
git commit -m "$(cat <<'EOF'
demo+docs(toolbar): W2 affordances showcase + api docs

Kitchen-sink: prominent tinted Compose, borderless badged Inbox with live
+1 / clear via updateItem. Document style/tintColor/badge/bordered + the
macOS-26 gate.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 8: HUMAN VISUAL GATE**

Hand off: `cd /Users/zach/code/zapp/kitchen-sink && bun run dev`. Ask the user to confirm in the Toolbar section / shell toolbar:
1. **Compose** renders prominent (purple-tinted background).
2. **Inbox** renders flat (no border) and shows a badge after "Inbox badge +1"; "Clear inbox badge" removes it.
3. The existing toolbar behaviors (Compose enable toggle, Filter moving checkmark, remove/attach) still work.

GO → W2 done. Issues → fix and re-smoke.

---

## Self-review notes

- **Spec coverage:** style+tint (T2/T3/T4/T5), badge incl. live+clear (T2/T3/T4/T5), bordered (T2/T3/T4/T5), TS↔Nim parity (T2+T3, round-trip test), macOS-26 gate + fallback (T4 `@available`), no iOS/C-ABI surface (T4 adds no exported symbols; T4 Step 5 iOS-sim build), showcase (T5), docs (T5), risk-gate-first (T1). All spec sections mapped.
- **Naming consistency:** `zapp_toolbar_apply_trio` / `zapp_toolbar_color` / `zapp_toolbar_badge` used identically in T4 builder + updateItem. Wire keys `style`/`tintColor`/`bordered`/`badge.{kind,count,text}` identical across T2 (TS emit), T3 (Nim emit+parse), T4 (native read). `badgeToWire` (TS) ↔ `ToolbarBadge`/serialize (Nim) produce the same shape.
- **Patch clear:** TS `badge:null` → `{kind:"none"}` (T2) → native `zapp_toolbar_badge` returns nil → `item.badge = nil` (T4). Consistent.
