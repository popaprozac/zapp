# Native Sidebar Windows (macOS v1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `Window.create({ sidebar: { url, ... } })` renders a real native macOS sidebar — `NSSplitViewController` root, `.sidebar` `NSSplitViewItem`, transparent fully-trusted WKWebView inside it (liquid glass on macOS 26).

**Architecture:** When `sidebar` options are present, window construction installs an `NSSplitViewController` as the window's `contentViewController` (sidebar item + content item) and creates TWO full-bootstrap webviews via a new mount-into-container path. Identity: the sidebar registers at its own dispatch slot (transport) but injects the HOST's windowId (identity) — window actions resolve to the host via the existing `slot → webview → .window` lookup. Window events fan out to both slots at the emit site. Control ops are t:4 `sidebar:*` actions → `darwin_sidebar_*` in a new `sidebar.m`.

**Tech Stack:** Objective-C (ARC), AppKit (`NSSplitViewController`/`NSSplitViewItem`), WebKit, Zen-C (window.zc/router.zc), TypeScript runtime (Bun, bun:test).

**Spec:** `docs/superpowers/specs/2026-06-10-native-sidebar-windows-design.md`
**Branch:** `feat/native-sidebar` (exists; spec committed).

---

## Context the engineer needs

- **Build success rule:** only `[zapp] build complete: <path>` as the LAST line is success. `bun run check` (tsc) is the type gate; `bun run build` does not type-check. Full gate: `bun run test:all`.
- **Commit discipline:** stage only files each task names. NEVER stage: `hello-world/src/main.ts`, `hello-world/src/worker.ts`, `hello-world/zapp.config.ts`, `vendor/bare`, `vendor/txiki.js`, `native/worker/engines/zjs-cross-eval-test.c`. Trailer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **Zen-C:** literal `{`/`}` in strings = `{{`/`}}`; `char* ==` is pointer compare; `raw { }` embeds C; Zen-C fns are plain C symbols (.m files extern them).
- **iOS parity rule (#281):** every `darwin_*` symbol referenced from shared `.zc` needs an `ios/` definition or the iOS link fails; `bun test ./cli/src/ios-platform-parity.test.ts` is the lint, the ios-sim build is the real gate.
- **Verbatim anchors (read 2026-06-10, current HEAD of feat/native-sidebar):**
  - `darwin/window.m` construction: titleBarStyle handling at ~400 (`int32_t tbs = wopts_title_bar_style_tag(opts); if (tbs == 1 || tbs == 2) { ...FullSizeContentView... }`); vibrancy branch ~481-505 installs `NSVisualEffectView` as contentView BEFORE webview creation; then `darwin_webview_create((__bridge void*)window, inspectable, accept_first_mouse, custom_url, wopts_numeric_id_pre_alloc(opts), useVibrancy);` — the 6th param is `transparent_background`. Delegate (`ZappWindowDelegate`) created after, with `.numericId` set later via `darwin_window_register_numeric_id`.
  - `darwin/window.m:172` `windowWillClose:` ONLY clears `zapp_webviews[self.numericId]` + `zapp_window_ids[...]` — close is REVERSIBLE (`setReleasedWhenClosed:NO`; show-after-close must still work). Real WKWebView teardown is in `darwin_window_destroy` (comment at ~556: "Only runs here — not in windowWillClose").
  - `darwin/window.m:80-110` window events are eval'd as `b.dispatchWindowEvent('<winId>','<event>', '<json>')` JS strings into the webview; native side also dispatches `zapp_dispatch_event(self.numericId, ZAPP_EVENT_WINDOW_*, w, h, x, y)` (delegate methods ~185-215).
  - `darwin/webview.m:762` `void darwin_webview_create(void* window_ptr, bool inspectable, bool accept_first_mouse, const char* url_override, int32_t numeric_id_pre_alloc, bool transparent_background)`. Its tail mount block (~1033-1045): `NSView* finalHost = [window contentView]; if ([finalHost isKindOfClass:[NSVisualEffectView class]]) { ...addSubview... } else { [window setContentView:webview]; }` — i.e. a "mount into pre-installed host" seam already exists; we generalize it.
  - Transparent webview path exists at webview.m ~1002-1012 (`drawsBackground` NO + clear layer) gated on `transparent_background`.
  - Re-parenting a WKWebView after first load RESETS its content process and breaks bootstrap (comment at window.m ~476 + webview.m mount comment) — webviews must be born in their final view tree.

## File structure

| File | Responsibility | Task |
|---|---|---|
| `runtime/window.ts` | `Material` const+type (retype `vibrancy`), `SidebarOptions`, `SidebarHandle`, `WindowOptions.sidebar`, `WindowHandle.sidebar`, `Window.isSidebar()`, 3 `WindowEvent`s, collapsed/width tracking | 1 |
| `runtime/window.test.ts` (new or extend existing) | Material values, sidebar option serialization, handle state tracking (pure parts) | 1 |
| `native/window/window.zc` | sidebar fields on `WindowOptions`, `window_opts_apply_json`, `wopts_sidebar_*` accessors | 2 |
| `native/app/router.zc` | t:4 `sidebar:*` routing → `darwin_sidebar_*` externs | 2 |
| `native/platform/darwin/sidebar.m` (new) | split registry, `darwin_sidebar_*` ops, split delegate → collapse/resize events | 3 |
| `native/platform/ios/sidebar.m` (new) | no-op stubs (parity) | 3 |
| `cli/src/native.ts` | add `sidebar.m` to BOTH platform source lists | 3 |
| `native/platform/darwin/webview.m` | mount-into-container + identity-override params (default path byte-equivalent); sidebar bootstrap flags | 4 |
| `native/platform/darwin/window.m` | construction branch (split root, second webview), chrome defaults, teardown (both sites), event fan-out | 5 |
| `docs/api-reference.md`, `docs/security.md`, `README.md` | docs | 6 |
| `hello-world/src/*` (user WIP — NEVER staged) | sidebar demo + smoke probes (cp-backup/restore) | 7 |

---

## Task 1: Runtime types + handle (TDD)

**Files:**
- Modify: `runtime/window.ts`
- Create or extend: `runtime/window.test.ts` (check `ls runtime/*.test.ts` — if a window test exists, extend it)
- Modify: `runtime/index.ts` (export `Material`, sidebar types)

- [ ] **Step 1: Failing tests.** Add to `runtime/window.test.ts`:

```ts
import { describe, expect, test } from "bun:test";
import { Material } from "./window";

describe("Material", () => {
  test("values are the wire strings", () => {
    expect(Material.Sidebar).toBe("sidebar");
    expect(Material.HeaderView).toBe("headerView");
    expect(Material.WindowBackground).toBe("windowBackground");
  });
  test("covers the full vibrancy set", () => {
    // Keep in lockstep with darwin/window.m's material mapping.
    expect(Object.values(Material).sort()).toEqual([
      "contentBackground", "fullScreenUI", "headerView", "hudWindow",
      "menu", "popover", "sheet", "sidebar", "titlebar",
      "underPageBackground", "underWindowBackground", "windowBackground",
    ].sort());
  });
});
```

Run: `bun test ./runtime/window.test.ts` → FAIL (Material not exported).

- [ ] **Step 2: Implement in `runtime/window.ts`.**

Add near the top (after imports):

```ts
/**
 * Native background materials (NSVisualEffectMaterial names). Used by the
 * window `vibrancy` option and `sidebar.material`. WindowEvent-style const —
 * `Material.Sidebar` autocompletes; plain string literals still type-check.
 * Keep in lockstep with the mapping in native/platform/darwin/window.m.
 */
export const Material = {
  Sidebar: "sidebar",
  HeaderView: "headerView",
  Titlebar: "titlebar",
  Menu: "menu",
  Popover: "popover",
  HudWindow: "hudWindow",
  FullScreenUI: "fullScreenUI",
  Sheet: "sheet",
  ContentBackground: "contentBackground",
  UnderWindowBackground: "underWindowBackground",
  UnderPageBackground: "underPageBackground",
  WindowBackground: "windowBackground",
} as const;
export type Material = (typeof Material)[keyof typeof Material];
```

(FIRST verify the exact material-name set against `darwin/window.m`'s mapping — `grep -n "isEqualToString" native/platform/darwin/window.m | grep -i material` region at ~486-497 — the list above was read from it; "windowBackground" is the implicit default and must be a valid value. Adjust the test + const together if the file differs.)

Retype the existing `vibrancy` option: find `vibrancy?:` in `WindowOptions` (it's a string-literal union today) and change to `vibrancy?: Material;` — non-breaking, same values.

Add the sidebar surface:

```ts
export interface SidebarOptions {
  /** Entry URL/route for the sidebar webview (resolved like the window url). Required. */
  url: string;
  /** Initial width in points. Default 260. */
  width?: number;
  /** Divider drag limits. Defaults 180 / 400. */
  minWidth?: number;
  maxWidth?: number;
  /** User can collapse via system behaviors. Default true. */
  collapsible?: boolean;
  /** Start collapsed. Default false. */
  collapsed?: boolean;
  /** Background material. Default Material.Sidebar (liquid glass on macOS 26+). */
  material?: Material;
}

export interface SidebarHandle {
  toggle(): void;
  collapse(): void;
  expand(): void;
  setWidth(px: number): void;
  /** Tracked from SIDEBAR_COLLAPSED/EXPANDED events, seeded by the create option. */
  readonly collapsed: boolean;
  /** Last width reported by SIDEBAR_RESIZED (or the create option until the first event). */
  readonly width: number;
}
```

In `WindowOptions` add `sidebar?: SidebarOptions;`. In the `WindowEvent` const add three entries following the file's existing naming/value pattern (READ the existing entries first — they map names to the wire event strings used by `dispatchWindowEvent`):

```ts
  SIDEBAR_COLLAPSED: "sidebar-collapsed",
  SIDEBAR_EXPANDED: "sidebar-expanded",
  SIDEBAR_RESIZED: "sidebar-resized",
```

On the window handle implementation: when the handle's options included `sidebar`, expose a `sidebar` property — an object whose methods post t:4 actions exactly like the existing window methods do (find how `setTitle` posts and mirror; the actions are `sidebar:toggle`, `sidebar:collapse`, `sidebar:expand`, `sidebar:setWidth` with `{ width }`), and which subscribes to the three new events to maintain `collapsed`/`width`. Seed `collapsed` from `opts.sidebar.collapsed ?? false`, `width` from `opts.sidebar.width ?? 260`. The handle must exist on handles returned by `Window.create` AND on `Window.current()`'s host handle when running in a sidebar (the bootstrap flag below tells us a sidebar exists — when `Symbol.for("zapp.isSidebar")` is true, current()'s handle gets a `sidebar` property too).

Add to the `Window` namespace:

```ts
  /** True when this code runs inside a window's sidebar webview. */
  isSidebar(): boolean {
    return (globalThis as any)[Symbol.for("zapp.isSidebar")] === true;
  },
```

Export from `runtime/index.ts`: extend the window export line with `Material, type SidebarOptions, type SidebarHandle`.

- [ ] **Step 3: Tests + check.** `bun test ./runtime/window.test.ts ./runtime/*.test.ts` all pass; `bun run check` clean.

- [ ] **Step 4: Commit** `runtime/window.ts runtime/window.test.ts runtime/index.ts`:

```
feat(runtime): Material const + sidebar window surface

Material.{Sidebar,...} typed catalog (vibrancy retyped to it,
non-breaking), SidebarOptions/SidebarHandle, WindowOptions.sidebar,
Window.isSidebar(), SIDEBAR_COLLAPSED/EXPANDED/RESIZED events, handle
state tracking (collapsed/width) seeded from options.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

---

## Task 2: Zen-C options + router actions

**Files:**
- Modify: `native/window/window.zc` (struct ~34-114, `window_opts_apply_json` ~254-473, plus the `wopts_*` accessor block — find it: `grep -n "fn wopts_" native/window/window.zc | head -30`)
- Modify: `native/app/router.zc` (t:4 action dispatch — the function whose body starts `let is_ready = action == "ready";`)

- [ ] **Step 1: Extend `WindowOptions` struct.** Following the existing field+`_heap` pattern (crib from `vibrancy: string; _vibrancy_heap: bool;`):

```zc
    // Sidebar (native NSSplitViewItem sidebar; macOS only).
    sidebarUrl: string;        // empty = no sidebar
    _sidebarUrl_heap: bool;
    sidebarMaterial: string;   // default "sidebar"
    _sidebarMaterial_heap: bool;
    sidebarWidth: int;         // default 260
    sidebarMinWidth: int;      // default 180
    sidebarMaxWidth: int;      // default 400
    sidebarCollapsible: bool;  // default true
    sidebarCollapsed: bool;    // default false
```

Set the defaults wherever `WindowOptions::create` initializes fields (read it; mirror the style — empty strings, the numeric defaults above, collapsible=true).

- [ ] **Step 2: Parse in `window_opts_apply_json`.** The TS sends `sidebar` as a nested object. Following the file's existing get_* idioms (and the nested-object precedent if one exists — check how `offset`/sheet options parse; if no nested precedent, use `args.get_object("sidebar")` per the JsonValue API used in permissions.zc):

```zc
    let sb_opt = args.get_object("sidebar");
    if sb_opt.is_some() {
        let sb = sb_opt.unwrap();
        let su = sb.get_string("url");
        if su.is_some() {
            raw {
                if (opts->_sidebarUrl_heap && opts->sidebarUrl) free((void*)opts->sidebarUrl);
                opts->sidebarUrl = strdup((const char*)su.unwrap());  // adapt unwrap placement to file style
                opts->_sidebarUrl_heap = 1;
            }
        }
        let sm = sb.get_string("material");
        if sm.is_some() { /* same strdup pattern into sidebarMaterial */ }
        let sw = sb.get_int("width");      if sw.is_some() { opts.sidebarWidth = sw.unwrap(); }
        let smin = sb.get_int("minWidth"); if smin.is_some() { opts.sidebarMinWidth = smin.unwrap(); }
        let smax = sb.get_int("maxWidth"); if smax.is_some() { opts.sidebarMaxWidth = smax.unwrap(); }
        let sc = sb.get_bool("collapsible"); if sc.is_some() { opts.sidebarCollapsible = sc.unwrap(); }
        let sco = sb.get_bool("collapsed");  if sco.is_some() { opts.sidebarCollapsed = sco.unwrap(); }
    }
```

**Adapt-point:** verify `get_object`/`get_bool` exist on this JsonValue (permissions.zc used `get_bool`; `grep -n "get_object\|get_bool" native/bridge/json_safe.zc` + crib a working nested-object consumer if different — `window_opts_apply_json` itself may already parse a nested `offset` for tray attach; check `grep -n "get_object" native/`). Also free the new heap fields in `window_opts_free` (find it; mirror vibrancy's free).

Add accessors next to the existing `wopts_*` block (these are what window.m externs):

```zc
fn wopts_sidebar_url(opts: WindowOptions*) -> string { return opts.sidebarUrl; }
fn wopts_sidebar_material(opts: WindowOptions*) -> string { return opts.sidebarMaterial; }
fn wopts_sidebar_width(opts: WindowOptions*) -> int { return opts.sidebarWidth; }
fn wopts_sidebar_min_width(opts: WindowOptions*) -> int { return opts.sidebarMinWidth; }
fn wopts_sidebar_max_width(opts: WindowOptions*) -> int { return opts.sidebarMaxWidth; }
fn wopts_sidebar_collapsible(opts: WindowOptions*) -> bool { return opts.sidebarCollapsible; }
fn wopts_sidebar_collapsed(opts: WindowOptions*) -> bool { return opts.sidebarCollapsed; }
```

(Match the exact receiver/param style of the existing wopts_ fns — read two of them first.)

- [ ] **Step 3: Router actions.** In the t:4 action-dispatch function, after the permission gate and near the `dock:`/`tray:` blocks, add (mirroring the dock block's `#ifdef __APPLE__` + extern style):

```zc
    if str::strncmp(action, "sidebar:", 8) == 0 {
        raw {
            #ifdef __APPLE__
            extern void darwin_sidebar_toggle(int32_t window_id);
            extern void darwin_sidebar_collapse(int32_t window_id);
            extern void darwin_sidebar_expand(int32_t window_id);
            extern void darwin_sidebar_set_width(int32_t window_id, int32_t width);
            #endif
        }
        if action == "sidebar:toggle"   { raw { #ifdef __APPLE__
            darwin_sidebar_toggle((int32_t)window_id); #endif } return; }
        if action == "sidebar:collapse" { raw { #ifdef __APPLE__
            darwin_sidebar_collapse((int32_t)window_id); #endif } return; }
        if action == "sidebar:expand"   { raw { #ifdef __APPLE__
            darwin_sidebar_expand((int32_t)window_id); #endif } return; }
        if action == "sidebar:setWidth" {
            let w_opt = pre_args.get_int("width");
            let w: int = 0;
            if w_opt.is_some() { w = w_opt.unwrap(); }
            raw { #ifdef __APPLE__
            darwin_sidebar_set_width((int32_t)window_id, (int32_t)w); #endif }
            return;
        }
        return;
    }
```

**Adapt:** match the file's real local names (`pre_args` vs `parsed.args` — read the dock/tray blocks in the same function and copy their exact extern/raw structure; PERM T4 added similar blocks recently, they're good cribs). NOTE: `window_id` here is the SENDER's slot — for sidebar-context senders that's the sidebar slot, not the host. `darwin_sidebar_*` must therefore resolve slot→host (Task 3 handles this: the registry maps BOTH slots to the split controller).

- [ ] **Step 4: Permission mapping stays ungated.** Verify `permission_id_for_action` returns `""` for `sidebar:*` (it will — no mapping added). Add a one-line comment in `permission_id_for_action`: `// sidebar:* = window ops on an existing window — ungated by design (docs/security.md).`

- [ ] **Step 5: Verify.** `bun run test:native` passes (no .zc test changes, compile sanity); macOS build will fail to LINK until Task 3 provides `darwin_sidebar_*` — so for THIS task verify compile-only via the iOS-sim build? No — iOS needs stubs too. Therefore: do NOT build at the end of this task; Task 3 lands the symbols and builds. Run only `bun run check` (clean) + `bun run test:native`.

- [ ] **Step 6: Commit** `native/window/window.zc native/app/router.zc`:

```
feat(native): sidebar window options + sidebar:* action routing

WindowOptions gains the sidebar fields (url/material/width/min/max/
collapsible/collapsed) with JSON parsing + wopts accessors; router routes
t:4 sidebar:toggle/collapse/expand/setWidth to darwin_sidebar_* (symbols
land with sidebar.m in the next commit). sidebar:* stays permission-ungated
(window ops on an existing window).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

---

## Task 3: `sidebar.m` (darwin) + iOS stubs + source registration

**Files:**
- Create: `native/platform/darwin/sidebar.m`
- Create: `native/platform/ios/sidebar.m`
- Modify: `cli/src/native.ts` (`getPlatformSources` — add `sidebar.m` to BOTH darwin and ios lists, next to `panel.m`)

- [ ] **Step 1: Find the event-string mechanism.** Before coding, read how window events reach JS: `sed -n '75,115p' native/platform/darwin/window.m` — the `dispatchWindowEvent('<winId>','<event>','<json>')` eval pattern, and what winId string is used (`win-%d` from numericId). The three new wire event names are `sidebar-collapsed`, `sidebar-expanded`, `sidebar-resized` (must match Task 1's WindowEvent values). Also find `darwin_window_eval_js(int32_t, const char*)`.

- [ ] **Step 2: Implement `native/platform/darwin/sidebar.m`:**

```objc
// Native sidebar (NSSplitViewController + .sidebar NSSplitViewItem) — the
// split registry + control ops + collapse/resize observation. Construction
// happens in window.m (the split must be the window's root before any
// webview loads); everything after lives here.
//
// Registry is keyed by the HOST window's numeric id, but sidebar:* actions
// can arrive from EITHER pane's slot (the sidebar webview has its own
// transport slot), so lookups resolve via the NSWindow, not the slot id.
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

extern void* darwin_window_get_by_numeric_id(int32_t numeric_id);
extern void darwin_window_eval_js(int32_t window_id, const char* js);

@interface ZappSidebarController : NSObject <NSSplitViewDelegate>
@property (nonatomic, strong) NSSplitViewController* splitVC;
@property (nonatomic, strong) NSSplitViewItem* sidebarItem;
@property (nonatomic, assign) int32_t hostWindowId;     // host slot (main webview)
@property (nonatomic, assign) int32_t sidebarSlotId;    // sidebar webview slot
@property (nonatomic, assign) BOOL lastCollapsed;
@end

static NSMutableDictionary<NSValue*, ZappSidebarController*>* zapp_sidebars = nil; // key: NSWindow*

static ZappSidebarController* zapp_sidebar_for_slot(int32_t slot_id) {
    void* wptr = darwin_window_get_by_numeric_id(slot_id);
    if (!wptr || !zapp_sidebars) return nil;
    return zapp_sidebars[[NSValue valueWithPointer:wptr]];
}

// Emit a window event string into BOTH panes (host + sidebar slots).
static void zapp_sidebar_emit(ZappSidebarController* c, const char* event, NSString* dataJson) {
    NSString* js = [NSString stringWithFormat:
        @"(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
        @"if(b&&typeof b.dispatchWindowEvent==='function'){b.dispatchWindowEvent('win-%d','%s',%@);}})();",
        c.hostWindowId, event, dataJson ? [NSString stringWithFormat:@"'%@'", dataJson] : @"undefined"];
    darwin_window_eval_js(c.hostWindowId, [js UTF8String]);
    if (c.sidebarSlotId >= 0) darwin_window_eval_js(c.sidebarSlotId, [js UTF8String]);
}

@implementation ZappSidebarController
// Collapse state changes (system toggle, programmatic, divider snap) are
// observable via the split item's `collapsed` KVO; resize via the delegate.
- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object
                        change:(NSDictionary*)change context:(void*)context {
    (void)object; (void)change; (void)context;
    if (![keyPath isEqualToString:@"collapsed"]) return;
    BOOL collapsed = self.sidebarItem.isCollapsed;
    if (collapsed == self.lastCollapsed) return;
    self.lastCollapsed = collapsed;
    zapp_sidebar_emit(self, collapsed ? "sidebar-collapsed" : "sidebar-expanded", nil);
}
- (void)splitViewDidResizeSubviews:(NSNotification*)notification {
    (void)notification;
    if (self.sidebarItem.isCollapsed) return;
    NSView* v = self.sidebarItem.viewController.view;
    int w = (int)v.frame.size.width;
    NSString* j = [NSString stringWithFormat:@"{\"width\":%d}", w];
    zapp_sidebar_emit(self, "sidebar-resized", j);
}
@end

// Called from window.m after construction to register the controller.
void zapp_sidebar_register(void* window_ptr, NSSplitViewController* splitVC,
                           NSSplitViewItem* sidebarItem, int32_t host_id, int32_t sidebar_slot_id) {
    if (!zapp_sidebars) zapp_sidebars = [NSMutableDictionary dictionary];
    ZappSidebarController* c = [[ZappSidebarController alloc] init];
    c.splitVC = splitVC;
    c.sidebarItem = sidebarItem;
    c.hostWindowId = host_id;
    c.sidebarSlotId = sidebar_slot_id;
    c.lastCollapsed = sidebarItem.isCollapsed;
    [sidebarItem addObserver:c forKeyPath:@"collapsed" options:NSKeyValueObservingOptionNew context:NULL];
    splitVC.splitView.delegate = (id<NSSplitViewDelegate>)c; // resize observation
    zapp_sidebars[[NSValue valueWithPointer:window_ptr]] = c;
}

// Called from window.m teardown (darwin_window_destroy path).
void zapp_sidebar_unregister(void* window_ptr) {
    if (!zapp_sidebars || !window_ptr) return;
    NSValue* key = [NSValue valueWithPointer:window_ptr];
    ZappSidebarController* c = zapp_sidebars[key];
    if (!c) return;
    @try { [c.sidebarItem removeObserver:c forKeyPath:@"collapsed"]; } @catch (NSException* e) {}
    c.splitVC.splitView.delegate = nil;
    [zapp_sidebars removeObjectForKey:key];
}

static void zapp_sidebar_on_main(void (^block)(void)) {
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

void darwin_sidebar_toggle(int32_t window_id) {
    zapp_sidebar_on_main(^{
        ZappSidebarController* c = zapp_sidebar_for_slot(window_id);
        if (!c) return;
        // Animated system toggle.
        [c.sidebarItem.animator setCollapsed:!c.sidebarItem.isCollapsed];
    });
}
void darwin_sidebar_collapse(int32_t window_id) {
    zapp_sidebar_on_main(^{
        ZappSidebarController* c = zapp_sidebar_for_slot(window_id);
        if (c && !c.sidebarItem.isCollapsed) [c.sidebarItem.animator setCollapsed:YES];
    });
}
void darwin_sidebar_expand(int32_t window_id) {
    zapp_sidebar_on_main(^{
        ZappSidebarController* c = zapp_sidebar_for_slot(window_id);
        if (c && c.sidebarItem.isCollapsed) [c.sidebarItem.animator setCollapsed:NO];
    });
}
void darwin_sidebar_set_width(int32_t window_id, int32_t width) {
    zapp_sidebar_on_main(^{
        ZappSidebarController* c = zapp_sidebar_for_slot(window_id);
        if (!c) return;
        CGFloat w = (CGFloat)width;
        if (w < c.sidebarItem.minimumThickness) w = c.sidebarItem.minimumThickness;
        if (c.sidebarItem.maximumThickness > 0 && w > c.sidebarItem.maximumThickness)
            w = c.sidebarItem.maximumThickness;
        [c.splitVC.splitView setPosition:w ofDividerAtIndex:0];
    });
}
```

**Adapt-points (verify against SDK, don't trust blindly):** (a) `NSSplitViewItem.animator setCollapsed:` is the documented animated-toggle idiom — confirm it compiles; if the animator proxy rejects it, fall back to `c.sidebarItem.collapsed = !...` inside `[NSAnimationContext runAnimationGroup:]`. (b) KVO keyPath `"collapsed"` on NSSplitViewItem — if KVO doesn't fire, observe via `NSSplitViewDidResizeSubviewsNotification` + collapse-state polling in the delegate callback instead (compare `isCollapsed` each resize) — keep the same emit semantics. (c) Setting `splitVC.splitView.delegate` may conflict with NSSplitViewController's own delegate ownership — if AppKit asserts, use the `splitViewDidResizeSubviews` NSNotification (`NSSplitViewDidResizeSubviewsNotification`, addObserver on the splitView) instead of stealing the delegate. Choose whichever works; the contract is only: emit `sidebar-resized {width}` on divider movement and collapse/expand events on state change.

- [ ] **Step 3: iOS stubs `native/platform/ios/sidebar.m`:**

```objc
// iOS sidebar stubs. The sidebar window option is macOS-only in v1; these
// no-ops satisfy the shared router.zc references on iOS (#ifdef __APPLE__
// is true on iOS too). UISplitViewController is the planned v2.
#import <Foundation/Foundation.h>
#import <stdint.h>

void darwin_sidebar_toggle(int32_t window_id) { (void)window_id; }
void darwin_sidebar_collapse(int32_t window_id) { (void)window_id; }
void darwin_sidebar_expand(int32_t window_id) { (void)window_id; }
void darwin_sidebar_set_width(int32_t window_id, int32_t width) { (void)window_id; (void)width; }
```

- [ ] **Step 4: Register sources.** In `cli/src/native.ts` `getPlatformSources`, add `"sidebar.m"` to BOTH the darwin and ios lists (next to `panel.m` in each).

- [ ] **Step 5: Verify.** `cd hello-world && bun run build 2>&1 | tail -1` → `[zapp] build complete:` (links Task 2's externs against sidebar.m; the register/unregister fns are not yet called — that's Task 5). `bun run build --platform ios 2>&1 | tail -1` → complete. `bun test ./cli/src/ios-platform-parity.test.ts` → pass.

- [ ] **Step 6: Commit** `native/platform/darwin/sidebar.m native/platform/ios/sidebar.m cli/src/native.ts`:

```
feat(native): sidebar.m — split registry, control ops, collapse/resize events

ZappSidebarController per window (keyed by NSWindow; sidebar:* actions can
arrive from either pane's slot so lookups resolve via the window):
toggle/collapse/expand animated via the split item, setWidth clamped to
min/max thickness, collapse KVO + divider-resize observation emitting
sidebar-collapsed/expanded/resized into BOTH panes. iOS no-op stubs.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

---

## Task 4: webview.m — mount-into-container + identity overrides

**Files:**
- Modify: `native/platform/darwin/webview.m` (signature ~762, bootstrap injection ~795-885, mount block ~1033-1045)

The default path must stay **byte-for-byte equivalent**. Mechanism: keep `darwin_webview_create` exactly as-is and add a wider sibling it delegates to.

- [ ] **Step 1: Widen the creation fn.** Rename the existing body to:

```objc
void darwin_webview_create_ext(void* window_ptr, bool inspectable, bool accept_first_mouse,
                               const char* url_override, int32_t numeric_id_pre_alloc,
                               bool transparent_background,
                               void* container_view /* NSView*, NULL = legacy mount */,
                               int32_t identity_window_id /* -1 = self (win-<own slot>) */,
                               bool is_sidebar) {
    ... existing body with the two changes below ...
}

void darwin_webview_create(void* window_ptr, bool inspectable, bool accept_first_mouse,
                           const char* url_override, int32_t numeric_id_pre_alloc,
                           bool transparent_background) {
    darwin_webview_create_ext(window_ptr, inspectable, accept_first_mouse, url_override,
                              numeric_id_pre_alloc, transparent_background, NULL, -1, false);
}
```

**Change A — identity injection.** In the bootstrap section where the windowId user script is built (~line 802: `NSString* windowId = (numeric_id_pre_alloc >= 0) ? [NSString stringWithFormat:@"win-%d", numeric_id_pre_alloc] : @"";`), use the identity override:

```objc
    int32_t identity_id = (identity_window_id >= 0) ? identity_window_id : numeric_id_pre_alloc;
    NSString* windowId = (identity_id >= 0)
        ? [NSString stringWithFormat:@"win-%d", identity_id]
        : @"";
```

And immediately after the existing windowId user-script block, add:

```objc
    if (is_sidebar) {
        [ucc addUserScript:[[WKUserScript alloc] initWithSource:
            @"(function(){globalThis[Symbol.for('zapp.isSidebar')]=true;})();"
            injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    }
```

(Adapt local names — `ucc` is the WKUserContentController in that section; read the surrounding block.)

**Change B — container mount.** Replace the tail mount block (currently `NSView* finalHost = [window contentView]; if NSVisualEffectView … else setContentView`) with:

```objc
    if (container_view) {
        NSView* host = (__bridge NSView*)container_view;
        [webview setFrame:host.bounds];
        [webview setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        [host addSubview:webview];
    } else {
        NSView* finalHost = [window contentView];
        if ([finalHost isKindOfClass:[NSVisualEffectView class]]) {
            [webview setFrame:finalHost.bounds];
            [webview setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
            [finalHost addSubview:webview];
        } else {
            [window setContentView:webview];
        }
    }
```

(The else-branch is the EXACT existing code, untouched.)

**Transport-vs-identity check (the spec's flagged unknown):** grep this file + bootstrap for what the injected windowId is used for in posts: `grep -n "subscribe" bootstrap/webview.ts native/app/router.zc | head`. The t:4 `subscribe` action registers window-event interest; it arrives on the SENDER's slot. With identity=host injected, sidebar subscriptions post with the host windowId in args but arrive on the sidebar slot — read `router.zc`'s subscribe handling to confirm which id it keys on. If it keys on the TRANSPORT slot (the `window_id` param), sidebar subscriptions register under the sidebar slot — which is FINE because Task 5's fan-out delivers events to the sidebar slot unconditionally; if it keys on an args windowId, it registers under host — also fine (host delivery already happens). Either way delivery works via the fan-out; document which in a code comment. If you find a path where it genuinely breaks, STOP and report (don't improvise identity plumbing).

- [ ] **Step 2: Verify byte-equivalence of the default path.** `cd hello-world && bun run build 2>&1 | tail -1` → complete. Headless regression: run `ZAPP_LOG=debug ./bin/hello-world` for 6s; `grep -c "window ready"` ≥ 1, workers boot, no errors. (No sidebar exists yet; this proves the refactor didn't disturb the legacy path.)

- [ ] **Step 3: Commit** `native/platform/darwin/webview.m`:

```
refactor(native): webview creation gains container-mount + identity overrides

darwin_webview_create_ext(container_view, identity_window_id, is_sidebar)
— mounts into a caller-provided view (the split item) instead of
contentView, injects a host windowId for sidebar identity (transport still
routes by the webview's own slot), and sets the zapp.isSidebar flag.
darwin_webview_create delegates with legacy args; the no-sidebar path is
byte-equivalent.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

---

## Task 5: window.m — construction branch, teardown, event fan-out

**Files:**
- Modify: `native/platform/darwin/window.m`

- [ ] **Step 1: Construction branch.** In `darwin_window_create`, locate the vibrancy block (~481) + the `darwin_webview_create(...)` call (~507). Restructure:

```objc
        const char* sidebarUrl = wopts_sidebar_url(opts);
        bool useSidebar = (sidebarUrl && sidebarUrl[0] != '\0');

        if (useSidebar) {
            // Sidebar windows: NSSplitViewController root. Chrome defaults to
            // the standard sidebar-app look unless titleBarStyle was explicit.
            if (tbs == 0) { // 0 = default/unset (verify the tag values in wopts_title_bar_style_tag's source)
                [window setStyleMask:([window styleMask] | NSWindowStyleMaskFullSizeContentView)];
                [window setTitleVisibility:NSWindowTitleHidden];
                [window setTitlebarAppearsTransparent:YES];
            }

            NSViewController* sideVC = [[NSViewController alloc] init];
            sideVC.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, wopts_sidebar_width(opts), wopts_height(opts))];
            NSViewController* contentVC = [[NSViewController alloc] init];
            contentVC.view = [[NSView alloc] initWithFrame:[window contentView].frame];

            // Optional vibrancy on the MAIN pane only (orthogonal to the sidebar
            // material): if useVibrancy, wrap contentVC's view content in the vfx
            // exactly like the legacy path — install the vfx as contentVC.view
            // and mount the main webview into it.
            NSView* mainContainer = contentVC.view;
            if (useVibrancy) {
                NSVisualEffectView* vfx = [[NSVisualEffectView alloc] initWithFrame:contentVC.view.frame];
                vfx.material = material;   // reuse the material var computed above; hoist it out of the `if (useVibrancy)` block so both paths share it
                vfx.blendingMode = NSVisualEffectBlendingModeBehindWindow;
                vfx.state = NSVisualEffectStateFollowsWindowActiveState;
                vfx.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
                contentVC.view = vfx;
                mainContainer = vfx;
            }

            NSSplitViewItem* sideItem = [NSSplitViewItem sidebarWithViewController:sideVC];
            sideItem.minimumThickness = (CGFloat)wopts_sidebar_min_width(opts);
            sideItem.maximumThickness = (CGFloat)wopts_sidebar_max_width(opts);
            sideItem.canCollapse = wopts_sidebar_collapsible(opts);
            NSSplitViewItem* contentItem = [NSSplitViewItem splitViewItemWithViewController:contentVC];

            NSSplitViewController* splitVC = [[NSSplitViewController alloc] init];
            [splitVC addSplitViewItem:sideItem];
            [splitVC addSplitViewItem:contentItem];
            window.contentViewController = splitVC;

            // Initial width: position divider after the controller is installed.
            [splitVC.splitView setPosition:(CGFloat)wopts_sidebar_width(opts) ofDividerAtIndex:0];
            if (wopts_sidebar_collapsed(opts)) sideItem.collapsed = YES;

            // Two full webviews, born in their final containers. Sidebar is
            // always transparent (material shows through); main pane follows
            // the legacy transparent rule (useVibrancy).
            int32_t host_slot = wopts_numeric_id_pre_alloc(opts);
            extern int32_t zapp_alloc_webview_slot(void); // see Step 2
            int32_t sidebar_slot = zapp_alloc_webview_slot();
            darwin_webview_create_ext((__bridge void*)window, inspectable, accept_first_mouse,
                                      custom_url, host_slot, useVibrancy,
                                      (__bridge void*)mainContainer, -1, false);
            darwin_webview_create_ext((__bridge void*)window, inspectable, accept_first_mouse,
                                      sidebarUrl, sidebar_slot, true,
                                      (__bridge void*)sideVC.view, host_slot, true);

            extern void zapp_sidebar_register(void*, NSSplitViewController*, NSSplitViewItem*, int32_t, int32_t);
            zapp_sidebar_register((__bridge void*)window, splitVC, sideItem, host_slot, sidebar_slot);
        } else if (useVibrancy) {
            ... existing vibrancy block, unchanged ...
        }
        if (!useSidebar) {
            darwin_webview_create((__bridge void*)window, inspectable, accept_first_mouse,
                                  custom_url, wopts_numeric_id_pre_alloc(opts), useVibrancy);
        }
```

**Adapt-points:** (a) hoist the `material` computation above both branches (it's currently inside `if (useVibrancy)`); the sidebar's OWN `material` option: when `wopts_sidebar_material` ≠ "sidebar", install an NSVisualEffectView with that material as `sideVC.view`'s background subview (same construction as the vibrancy block) — when it IS "sidebar" (default), do nothing: the `.sidebar` split item supplies the system material. (b) `wopts_numeric_id_pre_alloc` — find how slots are pre-allocated today (`grep -n "numeric_id_pre_alloc\|register_numeric_id" native/window/window.zc native/platform/darwin/window.m runtime/window.ts bootstrap/*.ts | head -15`); the sidebar slot must come from the SAME allocator. If allocation happens in Zen-C/TS (likely — the pre-alloc arrives via opts), add a `zapp_alloc_webview_slot`-equivalent where the allocator actually lives and thread it; if there's a native registration path (`darwin_window_register_numeric_id`), mirror it for the sidebar slot (the delegate also needs `sidebarNumericId` — Step 2). DO NOT invent a parallel id space. (c) The delegate's `shouldAutoShow` flow (bridge-ready gating) keys on the MAIN webview — confirm the sidebar webview loading later doesn't trip auto-show logic (it shouldn't; auto-show keys on the delegate's window).

- [ ] **Step 2: Delegate + teardown + fan-out.** `ZappWindowDelegate` gains `@property (nonatomic, assign) int32_t sidebarNumericId;` (default -1; set it in the construction branch).
  - **`windowWillClose:` (line ~172):** after clearing the main slot, also clear the sidebar slot:
    ```objc
    if (self.sidebarNumericId >= 0 && self.sidebarNumericId < ZAPP_MAX_WINDOW_CALLBACKS) {
        zapp_webviews[self.sidebarNumericId] = nil;
        zapp_window_ids[self.sidebarNumericId] = nil;
    }
    ```
  - **`darwin_window_destroy` (~556+):** find the existing WKWebView teardown block (the alpha.29 hardening: stopLoading + nil delegates + remove script handler). Apply the SAME sequence to the sidebar webview (locate it via the contentViewController split items or keep a delegate reference), then `extern void zapp_sidebar_unregister(void*); zapp_sidebar_unregister(handle);`. The main teardown's exact ops must be replicated — read that block and mirror it line-for-line for the second webview.
  - **Event fan-out:** find every `dispatchWindowEvent` eval site in this file (~80-110, the helpers building those JS strings keyed by numericId) and the `zapp_dispatch_event(self.numericId, ...)` delegate calls. The JS-eval delivery helper(s) gain: after eval into `numericId`'s webview, if the delegate's `sidebarNumericId >= 0`, eval the same string into that slot. If delivery happens via a single shared helper, one edit; if inline per-event, factor a tiny `zapp_window_event_eval(delegate, js)` helper and use it at each site. (The native `zapp_dispatch_event` callback path is for Zen-C callbacks — leave it keyed on the host id only.)

- [ ] **Step 3: Verify.**
  - `cd hello-world && bun run build 2>&1 | tail -1` + iOS build + parity lint — all green.
  - Headless regression (NO sidebar): boot, window ready, workers, zero behavior change.
  - Headless sidebar smoke: cp-backup `hello-world/src/main.ts`, append a temp auto-create:
    ```ts
    // [VERIFY-SIDEBAR temp]
    setTimeout(async () => {
      const w = await Window.create({ title: "Sidebar smoke", url: "#main",
        sidebar: { url: "#side", width: 240 } });
      setTimeout(() => { w.sidebar!.toggle(); }, 800);
      setTimeout(() => { w.sidebar!.toggle(); }, 1600);
    }, 1000);
    ```
    Build, run 8s with ZAPP_LOG=debug, assert: no crash; then restore main.ts (cp). Webview console isn't piped headless — the crash-free toggle loop + window logs are the assertion here; event delivery is asserted in Task 7's probe.
  - **Open→close→reopen loop** (teardown): extend the temp probe with `setTimeout(() => w.close(), 2400)` and create a second sidebar window after — run, assert no crash and no stale-slot errors in the log.

- [ ] **Step 4: Commit** `native/platform/darwin/window.m`:

```
feat(native): sidebar window construction, teardown, event fan-out

NSSplitViewController root when sidebar opts present: .sidebar item
(min/max thickness, canCollapse, initial width/collapsed) + content item
(vibrancy wraps the main pane only); two full webviews born in their final
containers via darwin_webview_create_ext (sidebar: own transport slot, host
identity, always transparent). Teardown mirrors the main webview at both
sites (windowWillClose slot clear — close stays reversible; full WKWebView
teardown + zapp_sidebar_unregister in darwin_window_destroy). Window-event
evals fan out to the sidebar slot.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

---

## Task 6: Docs

**Files:**
- Modify: `docs/api-reference.md` (Window section: `sidebar` option + `SidebarHandle` + the 3 events + `Material` + `Window.isSidebar()`), `docs/security.md` (one line in "Not gated in v1": sidebar control ops are window-ops-on-existing-window), `README.md` (Features bullet + platform-table row)

- [ ] **Step 1: api-reference.** In the Window section (find `## \`Window\`` / the Window.create options table), document: the `sidebar` option object (all 7 fields with defaults), the host-twin identity rules (`Window.current()` in the sidebar = host handle; `win.sidebar` is the handle from either pane; `Window.isSidebar()`), the events incl. `SIDEBAR_RESIZED {width}` + the divider/DOM-resize note, `Material` (and that `vibrancy` now accepts it), teardown semantics, macOS-only (iOS ignores with a log). Match the section's prose density; ~50-70 lines.
- [ ] **Step 2: README.** Features list, after the Window Management bullet:
```markdown
- **Native Sidebars** — `Window.create({ sidebar: { url } })` renders a real `NSSplitViewItem` sidebar: the actual system material (liquid glass on macOS 26), full-height under the titlebar, system collapse animation — with your web content inside it. No other web-shell framework can do this.
```
Platform table, after the Embedded webviews row: `| Native sidebar windows | ✅ | ⏳ UISplitViewController | ⏳ |`
- [ ] **Step 3: security.md.** In the "Not gated in v1 (by design)" paragraph, extend the window-ops mention: `window ops on existing windows (including sidebar toggle/resize)`.
- [ ] **Step 4: Verify + commit** the three files:

```
docs: native sidebar windows (api-reference, README, security note)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

---

## Task 7: hello-world demo + full smoke (user-WIP files: cp-backup, NEVER staged)

**Files:**
- Temp-modify (cp-backup/restore for probes) + leave demo in place uncommitted: `hello-world/src/main.ts`

- [ ] **Step 1: Demo + probe.** `cp hello-world/src/main.ts /tmp/main.sidebar.bak`. Add a demo button (next to the existing "New Window" buttons) the user keeps:

```ts
$("btn-new-window-sidebar")?.addEventListener("click", async () => {
  const w = await Window.create({
    title: "Sidebar Demo", width: 900, height: 600,
    url: "#main-pane",
    sidebar: { url: "#sidebar-pane", width: 240, minWidth: 180, maxWidth: 360 },
  });
  w.on(WindowEvent.SIDEBAR_COLLAPSED, () => log("sidebar collapsed"));
  w.on(WindowEvent.SIDEBAR_EXPANDED, () => log("sidebar expanded"));
  w.on(WindowEvent.SIDEBAR_RESIZED, (d: any) => log(`sidebar width ${d?.width}`));
});
```

plus the corresponding `<button id="btn-new-window-sidebar">New Window (sidebar)</button>` in the Window section markup, and a tiny hash-router branch in main.ts that renders a minimal sidebar UI when `location.hash === "#sidebar-pane"` (a list with `Events.emit("nav:select", ...)` on click; `background: transparent` body so the material shows) and a main-pane branch that `Events.on("nav:select")` → log. The demo IS the cross-pane round-trip proof.

- [ ] **Step 2: Automated assertion (temp, then restore).** Append a temp auto-probe that creates the sidebar window, has the SIDEBAR pane emit `Events.emit("sidebar:hello")` on boot, and the MAIN window (win-0) log on receipt — worker/main logs aren't visible from new windows headless either, so route the proof through a worker: main.ts's win-0 context does `Events.on("sidebar:hello", () => Workers.send("h-ticker", "ping", {replyTo: null}))`… simpler: have the probe call `Services.invoke("greet", {name: "sidebar"})` FROM the sidebar pane — the native service logs `service: greet called` (visible in ZAPP_LOG=debug stderr). Assertion: run headless 10s → grep the service-call log occurring AFTER window creation + zero crashes + the toggle loop from Task 5 still clean. Then `cp /tmp/main.sidebar.bak` — NO: the demo button should STAY for the user (uncommitted, their WIP file). Restore ONLY the temp auto-probe portion: keep the backup, re-apply the demo edits without the probe (or write the demo first, backup THAT, then append probe, then restore to demo-state). Concretely: (1) add demo, (2) `cp src/main.ts /tmp/main.with-demo.bak`, (3) append probe, build+run+assert, (4) `cp /tmp/main.with-demo.bak src/main.ts`, rebuild.

- [ ] **Step 3: Full gates.** `bun run test:all` green; macOS + iOS builds complete; parity lint. `git status` — confirm hello-world files are modified-but-unstaged and nothing else of ours is dirty.

- [ ] **Step 4: USER visual smoke (hand-off, not a commit):** report ready — the user clicks "New Window (sidebar)" on macOS 26 and verifies: liquid-glass material, full-height under titlebar with traffic-light inset, native collapse animation on toggle, divider drag respects min/max, width events log, nav clicks round-trip to the main pane.

---

## After all tasks: finish the branch

`superpowers:finishing-a-development-branch` — `bun run test:all`, then present merge/PR options (merge locally only; never push unasked).

---

## Self-review

**1. Spec coverage:** API (T1) · options→native (T2) · control ops + collapse/resize events from the split item, emitted to BOTH panes (T3) · container-mount + host-identity + isSidebar flag + the spec's flagged subscribe verification (T4) · split-root construction, chrome defaults, sidebar material override, both-site teardown checklist incl. ProcessThrottler hardening mirror + open/close/reopen loop, event fan-out (T5) · docs incl. ungated note (T6) · demo + cross-pane proof + user visual smoke (T7) · iOS ignore-with-stub + parity (T3/T5 gates) · Material retype non-breaking (T1). ✓
**2. Placeholders:** none — full code for new files; anchored snippets + verbatim-read context for edits; every adapt-point carries a discovery command and a STOP-если-broken instruction (the subscribe check, slot allocator, KVO/delegate fallbacks). ✓
**3. Symbol consistency:** `darwin_sidebar_toggle/collapse/expand/set_width` identical in T2 externs / T3 definitions / iOS stubs; `darwin_webview_create_ext(window_ptr, inspectable, accept_first_mouse, url, slot, transparent, container, identity_id, is_sidebar)` matches T4 def and T5 call sites; `zapp_sidebar_register/unregister` T3↔T5; wire event names `sidebar-collapsed/expanded/resized` T1 WindowEvent values ↔ T3 emit strings; `wopts_sidebar_*` T2↔T5. ✓
