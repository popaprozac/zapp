# Custom Icons in Menu Items Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `MenuItemDef.icon` (+ `iconTemplate`) so app menus, context menus, and tray menus can show SF Symbols, file-path images, or data-URL images on macOS.

**Architecture:** All three menu surfaces funnel through one native builder — `menu.m`'s `add_menu_item` (context menus via `build_menu_from_json`, tray menus via `darwin_menu_build_from_items_json`, both reaching it). So a single `item.image` insertion there, fed by a `static zapp_resolve_icon` helper in `menu.m`, covers everything. The TS side is two passthrough fields on `MenuItemDef`.

**Tech Stack:** TypeScript, Objective-C (`NSImage`/`NSMenuItem`/CoreGraphics), Bun.

**Branch:** `feat/menu-icons` (created, spec committed).

**Spec:** `docs/superpowers/specs/2026-06-05-menu-item-icons-design.md`

**Conventions:**
- Stage ONLY the files each task names. Never `git add -A`. Never stage `vendor/*`, `hello-world/*` (T3 is verify-only — no hello-world commit), `node_modules`, `native/worker/engines/zjs-cross-eval-test.c`, `benchmarks/*`.
- Build success = LAST line `[zapp] build complete: <path>` (NOT Vite's `✓ built`). `bun run build` does NOT type-check — run `bun run check` separately.
- macOS-only feature. `menu.m` is darwin-only and the helper is `.m`-internal (not referenced from `.zc`), so no `getPlatformSources`/`build.zc`/iOS-stub/parity work. iOS menus stay no-op.
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

## Task 1: `MenuItemDef.icon` + `iconTemplate` (TS field, passthrough)

**Files:**
- Modify: `runtime/menu.ts` (add the two fields to `MenuItemDef`)
- Verify (read-only): `runtime/menu.ts`, `runtime/tray.ts`, `runtime/context-menu.ts` `stripActions` keep unknown fields

- [ ] **Step 1: Add the fields to `MenuItemDef`**

In `runtime/menu.ts`, in the `MenuItemDef` interface, after the `submenu?: MenuItemDef[];` line, add:
```ts
  /** Icon for this item (macOS). "sf:gear" (SF Symbol) | "build/logo.png"
   *  (file path, relative-resolved) | "data:image/png;base64,…" (dynamic). */
  icon?: string;
  /** Force template rendering (monochrome, auto-tinted to menu text/dark mode)
   *  on/off. Default: "sf:" icons → true, file/data icons → false. */
  iconTemplate?: boolean;
```

- [ ] **Step 2: Confirm the three `stripActions` paths pass unknown fields through**

The fields must survive serialization to native in all three surfaces. Read each and confirm it copies-then-deletes (spread/`{...item}` keeping unknown keys), NOT a field whitelist:
- `runtime/menu.ts` — `stripActions` (deletes `action`, recurses `submenu`).
- `runtime/tray.ts` — `stripActions` (~line 192).
- `runtime/context-menu.ts` — `collectAndStrip` (~line 52).

Expected: each spreads the item and deletes only `action` (+ recurses `submenu`), so `icon`/`iconTemplate` pass through automatically. **If any one explicitly whitelists fields** (constructs a new object with only specific keys), add `icon: item.icon` and `iconTemplate: item.iconTemplate` to that copy. Report what you found per file.

- [ ] **Step 3: Type gate**

Run: `cd /Users/zach/code/zapp && bun run check 2>&1 | grep -c 'error TS'`
Expected: `0`.

- [ ] **Step 4: Commit (stage ONLY the files you changed)**

```bash
cd /Users/zach/code/zapp
git add runtime/menu.ts   # + tray.ts/context-menu.ts ONLY if Step 2 required an edit
git commit -m "$(cat <<'EOF'
feat(menu): MenuItemDef.icon + iconTemplate fields

Optional icon ("sf:…" / file path / "data:…") + template override on menu
items, passed through stripActions to native unchanged. Native rendering
follows. macOS only.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
git show --stat HEAD | tail -3
```

## CRITICAL constraints
- Stage ONLY `runtime/menu.ts` (and tray.ts/context-menu.ts only if Step 2 forced an edit). Never `git add -A`; never stage vendor/*, hello-world/*, node_modules, etc.

## Report Format
- **Status:** DONE | DONE_WITH_CONCERNS | BLOCKED
- Per-file finding for Step 2 (spread vs whitelist; any edit needed)
- `bun run check` count; commit SHA + `git show --stat HEAD`

---

## Task 2: Native icon rendering in `menu.m`

**Files:**
- Modify: `native/platform/darwin/menu.m` (add `zapp_resolve_icon` + `zapp_menu_template_mode` helpers; wire `item.image` in `add_menu_item`)

- [ ] **Step 1: Add the resolver + template-mode helpers**

In `native/platform/darwin/menu.m`, just ABOVE the `static void add_menu_item(NSMenu* menu, NSDictionary* def)` definition (it's right after the `static NSMenu* build_menu_from_json(NSArray* items);` forward declaration, ~line 132-134), add:
```objc
// Resolve a menu-icon spec to an NSImage (or nil). Forms:
//   "sf:<name>"                  -> SF Symbol (macOS 11+)
//   "data:<mime>;base64,<data>"  -> decode + initWithData
//   else                         -> file path, relative-resolved (cwd + bundle
//                                   resources), like tray.m apply_icon
// templateMode: -1 auto (template iff "sf:"), 0 off, 1 on. Sized to `size`.
// nil on failure (caller renders the item icon-less); logs once.
static NSImage* zapp_resolve_icon(NSString* spec, CGFloat size, int templateMode) {
    if (spec.length == 0) return nil;
    BOOL isSf = [spec hasPrefix:@"sf:"];
    NSImage* img = nil;
    if (isSf) {
        if (@available(macOS 11.0, *)) {
            img = [NSImage imageWithSystemSymbolName:[spec substringFromIndex:3]
                                accessibilityDescription:nil];
        }
    } else if ([spec hasPrefix:@"data:"]) {
        NSRange comma = [spec rangeOfString:@","];
        if (comma.location != NSNotFound) {
            NSString* b64 = [spec substringFromIndex:comma.location + 1];
            NSData* data = [[NSData alloc] initWithBase64EncodedString:b64
                              options:NSDataBase64DecodingIgnoreUnknownCharacters];
            if (data) img = [[NSImage alloc] initWithData:data];
        }
    } else {
        NSString* resolved = spec;
        if (![spec isAbsolutePath]) {
            NSFileManager* fm = [NSFileManager defaultManager];
            NSString* cwdRel = [[fm currentDirectoryPath] stringByAppendingPathComponent:spec];
            NSString* resPath = [NSBundle mainBundle].resourcePath;
            NSString* resRel = resPath ? [resPath stringByAppendingPathComponent:spec] : nil;
            if ([fm fileExistsAtPath:cwdRel]) resolved = cwdRel;
            else if (resRel && [fm fileExistsAtPath:resRel]) resolved = resRel;
        }
        img = [[NSImage alloc] initWithContentsOfFile:resolved];
    }
    if (!img) {
        NSLog(@"[zapp] menu: could not load icon '%@'", spec);
        return nil;
    }
    BOOL templateFlag = (templateMode == -1) ? isSf : (templateMode == 1);
    img.size = NSMakeSize(size, size);
    img.template = templateFlag;
    return img;
}

// iconTemplate: present -> 0/1; absent -> -1 (auto).
static int zapp_menu_template_mode(NSDictionary* def) {
    NSNumber* t = def[@"iconTemplate"];
    if (t != nil) return [t boolValue] ? 1 : 0;
    return -1;
}
```

- [ ] **Step 2: Wire `item.image` in `add_menu_item`**

In `add_menu_item`, AFTER the `checked` block:
```objc
    NSNumber* checked = def[@"checked"];
    if (checked) [item setState:[checked boolValue] ? NSControlStateValueOn : NSControlStateValueOff];
```
insert:
```objc
    NSString* iconSpec = def[@"icon"];
    if ([iconSpec isKindOfClass:[NSString class]] && iconSpec.length > 0) {
        NSImage* iconImg = zapp_resolve_icon(iconSpec, 16.0, zapp_menu_template_mode(def));
        if (iconImg) item.image = iconImg;
    }
```
(This runs for the regular-item path. Role-replacement items — `editMenu`/`windowMenu`/`appMenu` whole-menu roles — return early and don't take an icon, which is correct.)

- [ ] **Step 3: Verify the macOS build compiles**

Run: `cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -2`
Expected: last line `[zapp] build complete:`. (If clang errors — e.g. `imageWithSystemSymbolName` availability — confirm the `@available(macOS 11.0, *)` guard is present; fix + rebuild; report.)

- [ ] **Step 4: Commit (stage ONLY menu.m)**

```bash
cd /Users/zach/code/zapp
git add native/platform/darwin/menu.m
git commit -m "$(cat <<'EOF'
feat(menu): render MenuItemDef.icon natively (app/context/tray)

zapp_resolve_icon (sf: / data: / file-path, relative-resolved) + smart
template default (sf:→template, file/data→full-color, iconTemplate
override), sized 16px, nil-on-failure. Wired into add_menu_item, which all
three menu surfaces route through (context via build_menu_from_json, tray
via darwin_menu_build_from_items_json). Tray status-bar icon unchanged.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
git show --stat HEAD | tail -3
```

## CRITICAL constraints
- Stage ONLY `native/platform/darwin/menu.m`. Never `git add -A`; never stage vendor/*, hello-world/* (build dirties hello-world/bin), node_modules, etc.
- Build success = literal `[zapp] build complete:` last line.

## Report Format
- **Status:** DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
- Build final line (verbatim); any clang fix
- Commit SHA + `git show --stat HEAD` (only menu.m)
- Any concern

---

## Task 3: Docs + full verification

**Files:**
- Modify: `docs/api-reference.md` (document `icon`/`iconTemplate` in the Menu section)

- [ ] **Step 1: Document the icon fields**

In `docs/api-reference.md`, in the Menu (and/or Tray/Context) section where `MenuItemDef` is described, add a short subsection (match the file's heading depth + fenced-code style):
```markdown
### Menu item icons (macOS)

Any menu item (app menu, context menu, or tray menu) can show an icon via
`icon` — an SF Symbol, a file path, or a data-URL:

```ts
{ label: "Settings", icon: "sf:gear", action }          // SF Symbol
{ label: "Brand",    icon: "build/logo.png" }            // file path (relative-resolved)
{ label: "Status",   icon: canvas.toDataURL("image/png") } // dynamic PNG
```

- **Template tinting:** `sf:` icons render as templates (monochrome, auto-tinted
  to the menu text + dark mode); file/data icons render full-color. Override with
  `iconTemplate: true | false`.
- Icons are sized to ~16px. A bad path/symbol logs and renders the item without
  an icon (no crash). macOS only — ignored on other platforms.
```

- [ ] **Step 2: Verify fences + full gate**

```bash
cd /Users/zach/code/zapp
grep -c '```' docs/api-reference.md                    # even
bun run check 2>&1 | grep -c 'error TS'                # 0
bun run test:all 2>&1 | tail -6                         # TS + native + check green
cd hello-world && bun run build 2>&1 | tail -1          # [zapp] build complete:
bun run build --platform ios-simulator 2>&1 | tail -1  # [zapp] build complete: (confirms no break)
```

- [ ] **Step 3: Commit**

```bash
cd /Users/zach/code/zapp
git add docs/api-reference.md
git commit -m "$(cat <<'EOF'
docs(menu): document menu item icons (sf:/path/data-URL + template)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: Hand off the manual smoke checklist**

Report for the user's macOS smoke (via `bun run dev`): an `sf:` icon on an app-menu item tints with the text and flips in dark mode; a file-path PNG shows full color; a `data:` URL renders; the same `icon` works on a context-menu item and a tray-menu item; a bad path logs `[zapp] menu: could not load icon …` and the item shows text only.

---

## Self-Review (completed during plan authoring)

**Spec coverage:**
- `icon` (sf:/path/data-URL) + `iconTemplate` on `MenuItemDef` → Task 1. ✅
- Smart per-source template default + override → Task 2 (`zapp_resolve_icon` + `zapp_menu_template_mode`). ✅
- All three surfaces (app/context/tray) → Task 2 (single `add_menu_item` insertion; verified all route through it). ✅
- Sizing ~16px, nil-on-failure + log → Task 2. ✅
- Docs → Task 3. ✅
- macOS-only, no iOS/tray.m/build.zc changes → respected (single-builder discovery). ✅
- Verification (check/test:all/macOS+ios builds) → Task 3 (+ per-task). ✅
- Non-goals (sliders, menu-bar titles, tray status icon, raw bytes) → untouched. ✅

**Placeholder scan:** No TBD. Task 1 Step 2's "if a stripActions whitelists, add the fields" names the exact remedy + file — it's a verify-and-fix step, not a vague placeholder (the established pattern is spread+delete-action, so it almost certainly passes through unchanged).

**Type/name consistency:** `icon`/`iconTemplate` (TS) ↔ `def[@"icon"]`/`def[@"iconTemplate"]` (native); `zapp_resolve_icon(spec, size, templateMode)` + `zapp_menu_template_mode(def)` consistent between Step 1 (defs) and Step 2 (call); template tri-state `-1/0/1` matches between the two helpers; `16.0` size matches the spec's ~16px.
