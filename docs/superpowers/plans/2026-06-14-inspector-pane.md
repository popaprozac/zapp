# Inspector Pane (macOS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a trailing utility "inspector" pane (`NSSplitViewItem` inspector) completing the `sidebar | content | inspector` three-column native shell — a web-content pane mirroring the sidebar's declare-at-create + runtime show/hide lifecycle, with toolbar integration (`toggleInspector` + inspector-aware `trackingSeparator`).

**Architecture:** A window with an inspector roots on the existing `NSSplitViewController` with a trailing `inspectorWithViewController:` item (the symmetric partner of the leading `.sidebar` item). The native control/registry code is a parallel `inspector.m` mirroring `sidebar.m` (Approach A), sharing one extracted event-emit helper (Approach C). The window.m split builder is generalized to assemble 1–3 panes.

**Tech Stack:** TypeScript (runtime, bun:test), Objective-C (AppKit: `NSSplitViewController`/`NSSplitViewItem`/`NSToolbar`), Zen-C (`window.zc`, `router.zc`), Bun CLI.

**Spec:** `docs/superpowers/specs/2026-06-14-inspector-pane-design.md` (approved, committed `8aea69a`).

---

## Working rules (read first)

- **Branch:** all work on `feat/inspector-pane` (already cut from main). Never commit to main.
- **NEVER stage user-WIP:** `hello-world/src/main.ts`, `hello-world/src/worker.ts`, `hello-world/zapp.config.ts`, `vendor/bare`, `kitchen-sink/`, `native/worker/engines/zjs-cross-eval-test.c`. Stage by explicit path only — never `git add -A`/`-u`/`.`.
- **Commit trailer (exact):** end every commit with
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- **Build success** = the LAST line of build output is `[zapp] build complete: <path>` AND fresh binary mtime. Vite's `✓ built` line is NOT success.
- **`bun run build` does NOT type-check.** Type gate is `bun run check` (part of `bun run test:all`).
- **`bun test` uses the glob form** `bun test ./runtime/*.test.ts` — the bare-dir form EMFILEs on vendor/.
- Always Bun, never Node.
- Hello-world demo edits (Task 9) are fine but NEVER committed.

## File map

| Path | Change |
| --- | --- |
| `runtime/events.ts` | `INSPECTOR_COLLAPSED=17/EXPANDED=18/RESIZED=19` enum + names + payload type |
| `runtime/window.ts` | `InspectorOptions`/`InspectorHandle`; `createInspectorHandle`; `inspector` on `WindowHandle`; `Window.current()`/`Window.create`/`createWindowHandle` wiring; `Window.isInspector()`; `inspector:*` actions; `normalizeToolbar` gains `hasInspector` + `toggleInspector` + `trackingSeparator{pane}` |
| `runtime/events.test.ts`, `runtime/toolbar.test.ts` | tests |
| `native/window/window.zc` | inspector opts fields + `wopts_inspector_*` accessors + JSON parse + `WindowManager` inspector-slot pre-alloc |
| `native/platform/darwin/sidebar.m` | extract shared `zapp_pane_emit` (behavior-preserving) |
| `native/platform/darwin/inspector.m` (new) | `ZappInspectorController` + registry + control ops + `zapp_inspector_register/unregister` + `zapp_inspector_divider_index` |
| `native/platform/ios/inspector.m` (new) | 4 no-op `darwin_inspector_*` stubs |
| `native/platform/darwin/webview.m` | `create_ext` gains `host_has_sidebar`/`host_has_inspector`; `pane_role 3` → `zapp.isInspector`; explicit `hasSidebar`/`hasInspector` markers |
| `native/platform/darwin/popover.m` | update the one `create_ext` call site |
| `native/platform/darwin/window.m` | generalized split builder (inspector pane); inspector slot table + fan-out; metrics; teardown |
| `native/platform/darwin/toolbar.m` | `toggleInspector` item + `trackingSeparator{pane}` divider resolution |
| `native/app/router.zc` | `inspector:*` action block |
| `cli/src/native.ts` | add `inspector.m` to darwin + iOS source lists |
| `docs/api-reference.md` | Inspector section |

**Task order is load-bearing (each commit builds + links green):** runtime TS (1,2) → Zen-C accessors (3) → `inspector.m` + build sources + iOS stubs (4, compiles uncalled) → `webview.m` `create_ext` refactor (5, behavior-unchanged) → `window.m` construction (6, inspector renders at create) → router (7, runtime control works) → `toolbar.m` (8) → docs+demo+gates (9).

---

### Task 1: Runtime — inspector surface (events, options, handle, actions)

**Files:**
- Modify: `runtime/events.ts`
- Modify: `runtime/window.ts`
- Test: `runtime/events.test.ts`

- [ ] **Step 1: Write the failing test**

Append to `runtime/events.test.ts`:

```ts
import { eventName, WindowEvent } from "./events";

describe("inspector window events", () => {
  test("INSPECTOR_* map to window:inspector-* wire names", () => {
    expect(eventName(WindowEvent.INSPECTOR_COLLAPSED)).toBe("window:inspector-collapsed");
    expect(eventName(WindowEvent.INSPECTOR_EXPANDED)).toBe("window:inspector-expanded");
    expect(eventName(WindowEvent.INSPECTOR_RESIZED)).toBe("window:inspector-resized");
  });
});
```

(If `events.test.ts` already imports `eventName`/`WindowEvent`, add only the `describe` block.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/zach/code/zapp && bun test ./runtime/events.test.ts`
Expected: FAIL — `INSPECTOR_COLLAPSED` undefined → name resolves to `unknown:undefined`.

- [ ] **Step 3: Add the events**

In `runtime/events.ts`, after `POPOVER_CLOSED = 16,` in the `WindowEvent` enum:

```ts
  /** Fires when the inspector collapses. Payload: `{ windowId, timestamp }`. */
  INSPECTOR_COLLAPSED = 17,
  /** Fires when the inspector expands. Payload: `{ windowId, timestamp }`. */
  INSPECTOR_EXPANDED = 18,
  /** Fires when the inspector is resized. Payload: `{ windowId, width, timestamp }`. */
  INSPECTOR_RESIZED = 19,
```

In `WINDOW_EVENT_NAMES`, after the `[WindowEvent.POPOVER_CLOSED]: "window:popover-closed",` entry:

```ts
  [WindowEvent.INSPECTOR_COLLAPSED]: "window:inspector-collapsed",
  [WindowEvent.INSPECTOR_EXPANDED]: "window:inspector-expanded",
  [WindowEvent.INSPECTOR_RESIZED]: "window:inspector-resized",
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/zach/code/zapp && bun test ./runtime/events.test.ts`
Expected: PASS.

- [ ] **Step 5: Add the runtime surface in `window.ts`**

**5a — `InspectorOptions` + `InspectorHandle`.** After the `SidebarOptions` interface (the block ending `material?: Material;` for the sidebar, ~line 216), add:

```ts
/** Options for a native inspector (trailing NSSplitViewItem) attached to a window. */
export interface InspectorOptions {
  /** Entry URL/route for the inspector webview (resolved like sidebar.url). Required. */
  url: string;
  /** Initial width in points. Default 280. */
  width?: number;
  /** Divider drag limits. Defaults 180 / 400. */
  minWidth?: number;
  maxWidth?: number;
  /** User can collapse via system behaviors. Default true. */
  collapsible?: boolean;
  /** Start collapsed (the common "hidden until summoned" inspector). Default false. */
  collapsed?: boolean;
  /** Background material. Default matches the sidebar pane default. */
  material?: Material;
}
```

**5b — `WindowOptions` gains `inspector`.** In `WindowOptions`, right after the `toolbar?: ToolbarOptions;` member (~line 198):

```ts
  /** Attach a native inspector (trailing NSSplitViewItem). macOS only; no-op elsewhere. */
  inspector?: InspectorOptions;
```

**5c — the `InspectorHandle` interface.** After the `SidebarHandle` interface (ends with the `width` getter doc, ~line 419):

```ts
/** A handle to the inspector attached to a window. Mirrors SidebarHandle. */
export interface InspectorHandle {
  toggle(): void;
  collapse(): void;
  expand(): void;
  setWidth(px: number): void;
  /** Tracked from INSPECTOR_COLLAPSED/EXPANDED, seeded by the create option. */
  readonly collapsed: boolean;
  /** Last width from INSPECTOR_RESIZED (the create option until the first event). */
  readonly width: number;
}
```

**5d — `WindowHandle` gains `inspector`.** In the `WindowHandle` interface, right after `readonly sidebar?: SidebarHandle;` (~line 428):

```ts
  /** Handle for the inspector attached to this window, if any. */
  readonly inspector?: InspectorHandle;
```

**5e — state + handle factory.** After `createSidebarHandle` (ends ~line 555), add the inspector twin (mirrors the sidebar's module-state + once-wired-listeners pattern):

```ts
/** Per-window inspector state, shared across repeated Window.current() calls. */
const inspectorState = new Map<string, { collapsed: boolean; width: number }>();
/** Windows whose inspector event listeners are already registered. */
const inspectorWired = new Set<string>();

/** Create an InspectorHandle that tracks collapsed/width state via events. */
function createInspectorHandle(
  windowId: string,
  initialCollapsed: boolean,
  initialWidth: number,
): InspectorHandle {
  if (!inspectorState.has(windowId)) {
    inspectorState.set(windowId, { collapsed: initialCollapsed, width: initialWidth });
  }
  if (!inspectorWired.has(windowId)) {
    const bridge = getBridge();
    bridge.on(eventName(WindowEvent.INSPECTOR_COLLAPSED), (payload: any) => {
      if (payload?.windowId === windowId) inspectorState.get(windowId)!.collapsed = true;
    });
    bridge.on(eventName(WindowEvent.INSPECTOR_EXPANDED), (payload: any) => {
      if (payload?.windowId === windowId) inspectorState.get(windowId)!.collapsed = false;
    });
    bridge.on(eventName(WindowEvent.INSPECTOR_RESIZED), (payload: any) => {
      if (payload?.windowId === windowId && typeof payload.width === "number") {
        inspectorState.get(windowId)!.width = payload.width;
      }
    });
    inspectorWired.add(windowId);
  }
  return {
    get collapsed() { return inspectorState.get(windowId)!.collapsed; },
    get width()     { return inspectorState.get(windowId)!.width; },
    toggle()              { windowAction("inspector:toggle",   { windowId }); },
    collapse()            { windowAction("inspector:collapse", { windowId }); },
    expand()              { windowAction("inspector:expand",   { windowId }); },
    setWidth(px: number)  { windowAction("inspector:setWidth", { windowId, width: px }); },
  };
}
```

**5f — `createWindowHandle` gains the inspector param + property.** Change the signature (~line 557) from
`function createWindowHandle(windowId: string, sidebarOpts?: SidebarOptions): WindowHandle {`
to:

```ts
function createWindowHandle(windowId: string, sidebarOpts?: SidebarOptions, inspectorOpts?: InspectorOptions): WindowHandle {
```

In the returned handle object, right after the `sidebar:` property (~line 601-603):

```ts
    inspector: inspectorOpts !== undefined
      ? createInspectorHandle(windowId, inspectorOpts.collapsed ?? false, inspectorOpts.width ?? 280)
      : undefined,
```

**5g — `Window.current()` wires the inspector.** In `Window.current()` (~line 645), mirror the sidebar block. After the existing sidebar `sidebarOpts` computation and right before `return createWindowHandle(id, sidebarOpts);`:

```ts
    const inInspectorWindow = Window.isInspector() ||
      (globalThis as any)[Symbol.for("zapp.hasInspector")] === true;
    const inspectorOpts: InspectorOptions | undefined = inInspectorWindow
      ? { url: "" }  // url unused here — the pane is already running; we only need the shape.
      : undefined;
    return createWindowHandle(id, sidebarOpts, inspectorOpts);
```

(Replace the existing `return createWindowHandle(id, sidebarOpts);` with the block above.)

**5h — `Window.isInspector()`.** After the `isSidebar()` method in the `Window` object (~line 668):

```ts
  /** True when this code runs inside a window's inspector webview. */
  isInspector(): boolean {
    return (globalThis as any)[Symbol.for("zapp.isInspector")] === true;
  },
```

**5i — `Window.create` passes the inspector to the handle.** In `Window.create`, both `createWindowHandle(...)` calls (the worker-host path ~line 708 and the webview-invoke path ~line 713) take a 3rd arg:

```ts
    // worker-host path:
    return createWindowHandle(r.windowId, opts?.sidebar, opts?.inspector);
    // webview-invoke path:
    return createWindowHandle(result.windowId, opts?.sidebar, opts?.inspector);
```

(The `inspector` options object already passes through to native in `normalized` via the `{ ...(opts ?? {}) }` spread — like `sidebar`, it is NOT deleted.)

- [ ] **Step 6: Run the full runtime suite + type-check**

Run: `cd /Users/zach/code/zapp && bun test ./runtime/*.test.ts && bun run check`
Expected: PASS, tsc clean. (`inspector:*` windowActions no-op until the router lands — fine.)

- [ ] **Step 7: Commit**

```bash
cd /Users/zach/code/zapp
git add runtime/events.ts runtime/window.ts runtime/events.test.ts
git commit -m "$(cat <<'EOF'
feat(runtime): inspector pane surface — InspectorOptions/Handle + events

INSPECTOR_COLLAPSED/EXPANDED/RESIZED (17-19); win.inspector handle
mirroring SidebarHandle (toggle/collapse/expand/setWidth + collapsed/
width tracked via events); Window.current() wires it via zapp.isInspector
/hasInspector; Window.isInspector(); inspector:* windowActions. Native +
router land in later tasks (actions no-op until then).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Runtime — toolbar inspector integration (`normalizeToolbar`)

**Files:**
- Modify: `runtime/window.ts`
- Test: `runtime/toolbar.test.ts`

The existing `normalizeToolbar(toolbar, hasSidebar)` validates `toggleSidebar`/`trackingSeparator` (require a sidebar) and pushes `{ type }`. Add a `hasInspector` parameter, a `toggleInspector` system type, and a `pane?: "sidebar" | "inspector"` field on `trackingSeparator`.

- [ ] **Step 1: Write the failing tests**

Append to `runtime/toolbar.test.ts`:

```ts
describe("normalizeToolbar inspector integration", () => {
  test("toggleInspector kept when window has an inspector", () => {
    const { json } = normalizeToolbar(
      { items: [{ type: "toggleInspector" }] } as any, false, true,
    );
    expect(JSON.parse(json).items).toEqual([{ type: "toggleInspector" }]);
  });

  test("toggleInspector dropped + warned when no inspector", () => {
    const { json } = normalizeToolbar(
      { items: [{ type: "toggleInspector" }, { id: "a" }] } as any, false, false,
    );
    expect(JSON.parse(json).items).toEqual([{ type: "button", id: "a", label: "", icon: "" }]);
  });

  test("trackingSeparator pane defaults to sidebar", () => {
    const { json } = normalizeToolbar(
      { items: [{ type: "trackingSeparator" }] }, true, false,
    );
    expect(JSON.parse(json).items).toEqual([{ type: "trackingSeparator", pane: "sidebar" }]);
  });

  test("inspector trackingSeparator kept when window has an inspector", () => {
    const { json } = normalizeToolbar(
      { items: [{ type: "trackingSeparator", pane: "inspector" }] } as any, false, true,
    );
    expect(JSON.parse(json).items).toEqual([{ type: "trackingSeparator", pane: "inspector" }]);
  });

  test("inspector trackingSeparator dropped when no inspector", () => {
    const { json } = normalizeToolbar(
      { items: [{ type: "trackingSeparator", pane: "inspector" }, { id: "a" }] } as any, false, false,
    );
    expect(JSON.parse(json).items).toEqual([{ type: "button", id: "a", label: "", icon: "" }]);
  });

  test("sidebar trackingSeparator still requires a sidebar", () => {
    const { json } = normalizeToolbar(
      { items: [{ type: "trackingSeparator" }, { id: "a" }] }, false, false,
    );
    expect(JSON.parse(json).items).toEqual([{ type: "button", id: "a", label: "", icon: "" }]);
  });
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd /Users/zach/code/zapp && bun test ./runtime/toolbar.test.ts`
Expected: FAIL (`normalizeToolbar` takes 2 args; no `toggleInspector`/`pane` handling).

- [ ] **Step 3: Update `ToolbarItemDef` + `normalizeToolbar`**

In `runtime/window.ts`:

**3a.** In `ToolbarItemDef`, widen `type` and add `pane`. Replace the `type?:` line (~line 229):

```ts
  type?: "button" | "toggleSidebar" | "toggleInspector" | "trackingSeparator" | "space" | "flexibleSpace";
  /** For `trackingSeparator`: which split divider to track. Default "sidebar". */
  pane?: "sidebar" | "inspector";
```

**3b.** Change `normalizeToolbar`'s signature (~line 366) to add `hasInspector`:

```ts
export function normalizeToolbar(
  toolbar: ToolbarOptions,
  hasSidebar: boolean,
  hasInspector: boolean,
): {
```

**3c.** Replace the system-item handling block. The current block (~lines 375-388) is:

```ts
    const type = item.type ?? "button";
    if (type === "toggleSidebar" || type === "trackingSeparator") {
      if ((item as any).menu) throw new Error('[zapp] toolbar: "menu" is only valid on button items');
      if (!hasSidebar) {
        console.warn(`[zapp] toolbar: "${type}" requires the window to have a sidebar — item dropped`);
        continue;
      }
      items.push({ type });
      continue;
    }
    if (type === "space" || type === "flexibleSpace") {
      if ((item as any).menu) throw new Error('[zapp] toolbar: "menu" is only valid on button items');
      items.push({ type });
      continue;
    }
```

Replace it with:

```ts
    const type = item.type ?? "button";
    if (type === "toggleSidebar") {
      if ((item as any).menu) throw new Error('[zapp] toolbar: "menu" is only valid on button items');
      if (!hasSidebar) {
        console.warn(`[zapp] toolbar: "toggleSidebar" requires the window to have a sidebar — item dropped`);
        continue;
      }
      items.push({ type });
      continue;
    }
    if (type === "toggleInspector") {
      if ((item as any).menu) throw new Error('[zapp] toolbar: "menu" is only valid on button items');
      if (!hasInspector) {
        console.warn(`[zapp] toolbar: "toggleInspector" requires the window to have an inspector — item dropped`);
        continue;
      }
      items.push({ type });
      continue;
    }
    if (type === "trackingSeparator") {
      if ((item as any).menu) throw new Error('[zapp] toolbar: "menu" is only valid on button items');
      const pane = item.pane ?? "sidebar";
      const ok = pane === "inspector" ? hasInspector : hasSidebar;
      if (!ok) {
        console.warn(`[zapp] toolbar: "trackingSeparator" (pane: "${pane}") requires the window to have a ${pane} — item dropped`);
        continue;
      }
      items.push({ type, pane });
      continue;
    }
    if (type === "space" || type === "flexibleSpace") {
      if ((item as any).menu) throw new Error('[zapp] toolbar: "menu" is only valid on button items');
      items.push({ type });
      continue;
    }
```

- [ ] **Step 4: Update `normalizeToolbar` call sites**

Both call sites pass `opts.inspector !== undefined` (or the handle's `inspectorOpts`) as the new 3rd arg:

- In `Window.create` (~line 689):
  ```ts
      const { json, actions, menuActions, menuIdsByItem } = normalizeToolbar(opts.toolbar, opts.sidebar !== undefined, opts.inspector !== undefined);
  ```
- In the `toolbar.setItems` handle method inside `createWindowHandle` (the `normalizeToolbar({ items, style: setOpts?.style }, sidebarOpts !== undefined)` call):
  ```ts
        const { json, actions, menuActions, menuIdsByItem } =
          normalizeToolbar({ items, style: setOpts?.style }, sidebarOpts !== undefined, inspectorOpts !== undefined);
  ```

- [ ] **Step 5: Run tests + type-check**

Run: `cd /Users/zach/code/zapp && bun test ./runtime/toolbar.test.ts && bun run check`
Expected: PASS, tsc clean.

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add runtime/window.ts runtime/toolbar.test.ts
git commit -m "$(cat <<'EOF'
feat(runtime): toolbar inspector integration — toggleInspector + tracking pane

normalizeToolbar gains a hasInspector param; toggleInspector is a system
item gated on an inspector; trackingSeparator gains pane?: "sidebar" |
"inspector" (default "sidebar", backward-compatible) gated on the matching
pane. Native toolbar.m consumes the wire shape in a later task.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Zen-C — `window.zc` inspector opts, accessors, slot pre-alloc

**Files:**
- Modify: `native/window/window.zc`

Mirror the sidebar opts (`window.zc:89-112` fields, `:244-253` accessors, `:373-403` JSON parse, `:591-599` dispose, `:779-780` slot pre-alloc).

- [ ] **Step 1: Add the struct fields**

In the `WindowOptions` struct, after the sidebar fields block (after `sidebarCollapsed: bool;`, ~line 98) and the `sidebarNumericId: int;` field (~line 112), add an inspector block. Put the option fields next to the sidebar ones:

```zc
    // Inspector (trailing NSSplitViewItem inspector; macOS only).
    inspectorUrl: string;        // empty = no inspector
    _inspectorUrl_heap: bool;
    inspectorMaterial: string;   // default "sidebar"
    _inspectorMaterial_heap: bool;
    inspectorWidth: int;         // default 280
    inspectorMinWidth: int;      // default 180
    inspectorMaxWidth: int;      // default 400
    inspectorCollapsible: bool;  // default true
    inspectorCollapsed: bool;    // default false
```

And next to `sidebarNumericId: int;` (~line 112):

```zc
    // Transport slot for the inspector webview (same id-space as
    // numericIdPreAlloc / sidebarNumericId). -1 = no inspector.
    inspectorNumericId: int;
```

- [ ] **Step 2: Add the defaults**

In the struct initializer (where `sidebarCollapsed: false,` and `sidebarNumericId: -1,` are, ~lines 197-207), add:

```zc
            inspectorUrl: "",
            _inspectorUrl_heap: false,
            inspectorMaterial: "",
            _inspectorMaterial_heap: false,
            inspectorWidth: 280,
            inspectorMinWidth: 180,
            inspectorMaxWidth: 400,
            inspectorCollapsible: true,
            inspectorCollapsed: false,
            inspectorNumericId: -1,
```

- [ ] **Step 3: Add the accessors**

After the sidebar accessors (`wopts_sidebar_collapsed`, ~line 253):

```zc
fn wopts_inspector_numeric_id(opts: WindowOptions*) -> int { return opts.inspectorNumericId; }
fn wopts_inspector_url(opts: WindowOptions*) -> string { return opts.inspectorUrl; }
fn wopts_inspector_material(opts: WindowOptions*) -> string { return opts.inspectorMaterial; }
fn wopts_inspector_width(opts: WindowOptions*) -> int { return opts.inspectorWidth; }
fn wopts_inspector_min_width(opts: WindowOptions*) -> int { return opts.inspectorMinWidth; }
fn wopts_inspector_max_width(opts: WindowOptions*) -> int { return opts.inspectorMaxWidth; }
fn wopts_inspector_collapsible(opts: WindowOptions*) -> bool { return opts.inspectorCollapsible; }
fn wopts_inspector_collapsed(opts: WindowOptions*) -> bool { return opts.inspectorCollapsed; }
```

- [ ] **Step 4: Parse the `inspector` JSON object**

After the sidebar parse block (ends ~line 403 with `let sco = (*sb).get_bool("collapsed"); ...`), add the inspector twin. Mirror the sidebar's raw `strdup` idiom exactly:

```zc
    let insp_opt = args.get_object("inspector");
    if insp_opt.is_some() {
        let insp = insp_opt.unwrap();
        let iu = (*insp).get_string("url");
        if iu.is_some() {
            let src: string = iu.unwrap();
            raw {
                if (opts->_inspectorUrl_heap && opts->inspectorUrl) free((void*)opts->inspectorUrl);
                opts->inspectorUrl = strdup((const char*)src);
                opts->_inspectorUrl_heap = 1;
            }
        }
        let im = (*insp).get_string("material");
        if im.is_some() {
            let src: string = im.unwrap();
            raw {
                if (opts->_inspectorMaterial_heap && opts->inspectorMaterial) free((void*)opts->inspectorMaterial);
                opts->inspectorMaterial = strdup((const char*)src);
                opts->_inspectorMaterial_heap = 1;
            }
        }
        let iw = (*insp).get_int("width");        if iw.is_some() { opts.inspectorWidth = iw.unwrap(); }
        let imin = (*insp).get_int("minWidth");   if imin.is_some() { opts.inspectorMinWidth = imin.unwrap(); }
        let imax = (*insp).get_int("maxWidth");   if imax.is_some() { opts.inspectorMaxWidth = imax.unwrap(); }
        let ic = (*insp).get_bool("collapsible"); if ic.is_some() { opts.inspectorCollapsible = ic.unwrap(); }
        let ico = (*insp).get_bool("collapsed");  if ico.is_some() { opts.inspectorCollapsed = ico.unwrap(); }
    }
```

- [ ] **Step 5: Free the heap strings on dispose**

In the dispose/free block (where sidebar strings are freed, ~lines 591-599), add after the sidebar frees:

```zc
        if (opts->_inspectorUrl_heap && opts->inspectorUrl) {
            free((void*)opts->inspectorUrl);
            opts->inspectorUrl = "";
            opts->_inspectorUrl_heap = 0;
        }
        if (opts->_inspectorMaterial_heap && opts->inspectorMaterial) {
            free((void*)opts->inspectorMaterial);
            opts->inspectorMaterial = "";
            opts->_inspectorMaterial_heap = 0;
        }
```

- [ ] **Step 6: Pre-allocate the inspector transport slot**

In `WindowManager.create`, the sidebar slot is reserved at `native/window/window.zc:779-782`, immediately before `let handle = window_create(options);`:

```zc
        if options.sidebarUrl != "" {
            options.sidebarNumericId = self.next_id;
            self.next_id += 1;
        }
```

Add the inspector twin directly after it (still before `window_create`, so the slot is reserved when the native side reads `wopts_inspector_numeric_id`):

```zc
        if options.inspectorUrl != "" {
            options.inspectorNumericId = self.next_id;
            self.next_id += 1;
        }
```

- [ ] **Step 7: Build (Zen-C compile gate)**

Run: `cd /Users/zach/code/zapp/hello-world && bun run build`
Expected: LAST line `[zapp] build complete: <path>`. (Accessors unused until Task 6 — compiles clean.)

- [ ] **Step 8: Commit**

```bash
cd /Users/zach/code/zapp
git add native/window/window.zc
git commit -m "$(cat <<'EOF'
feat(window.zc): inspector window options, accessors, slot pre-alloc

Mirror of the sidebar opts — inspector url/material/width/min/max/
collapsible/collapsed + wopts_inspector_* accessors + JSON parse of the
nested "inspector" object + a pre-allocated inspector transport slot
(same id-space as sidebarNumericId).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Native — `inspector.m` (controller + registry + control ops) + iOS stubs + build sources

**Files:**
- Modify: `native/platform/darwin/sidebar.m` (extract `zapp_pane_emit`)
- Create: `native/platform/darwin/inspector.m`
- Create: `native/platform/ios/inspector.m`
- Modify: `cli/src/native.ts` (source lists)

- [ ] **Step 1: Extract the shared emit helper in `sidebar.m`**

In `native/platform/darwin/sidebar.m`, replace the `static void zapp_sidebar_emit(...)` function (lines ~64-90) with a thin wrapper that delegates to a new exported `zapp_pane_emit`. Put `zapp_pane_emit` ABOVE `zapp_sidebar_emit`:

```objc
// Shared pane event-emit: dispatch a window event into the host pane and one
// accessory pane (sidebar or inspector). eventName is the BARE suffix
// ("sidebar-collapsed" / "inspector-resized" etc.); dispatchWindowEvent in
// bootstrap/webview.ts prepends "window:". dataJson may be nil. Single-quoted
// JSON literal, backslash + quote escaped. Exported — also used by inspector.m.
void zapp_pane_emit(int32_t host_id, int32_t accessory_slot,
                    const char* eventName, NSString* dataJson) {
    if (!eventName) return;
    NSString* dataArg = @"undefined";
    if (dataJson) {
        NSString* esc = [dataJson stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
        esc = [esc stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
        dataArg = [NSString stringWithFormat:@"'%@'", esc];
    }
    NSString* event = [NSString stringWithUTF8String:eventName];
    NSString* js = [NSString stringWithFormat:
        @"(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
        @"if(b&&typeof b.dispatchWindowEvent==='function'){"
        @"b.dispatchWindowEvent('win-%d','%@',%@);}})();",
        host_id, event, dataArg];
    const char* jsc = [js UTF8String];
    darwin_window_eval_js(host_id, jsc);
    if (accessory_slot >= 0 && accessory_slot != host_id) {
        darwin_window_eval_js(accessory_slot, jsc);
    }
}

// Emit a window event into both sidebar panes (host + sidebar slot).
static void zapp_sidebar_emit(ZappSidebarController* c, const char* eventName, NSString* dataJson) {
    if (!c) return;
    zapp_pane_emit(c.hostWindowId, c.sidebarSlotId, eventName, dataJson);
}
```

(Behavior-preserving: the JS string is identical to the original. `darwin_window_eval_js` is already declared/used in sidebar.m.)

- [ ] **Step 2: Create `native/platform/darwin/inspector.m`**

```objc
// Native inspector (trailing NSSplitViewItem inspector) — parallel to
// sidebar.m. Registry keyed by the host NSWindow; control ops resolve the
// controller via the host slot (works from any pane of the window). Shares
// the event-emit helper (zapp_pane_emit) with sidebar.m.
#import <Cocoa/Cocoa.h>
#import <math.h>

extern void* darwin_window_get_by_numeric_id(int32_t numeric_id);
extern void zapp_pane_emit(int32_t host_id, int32_t accessory_slot,
                           const char* eventName, NSString* dataJson);

@interface ZappInspectorController : NSObject
@property (nonatomic, strong) NSSplitViewController* splitVC;
@property (nonatomic, strong) NSSplitViewItem* inspectorItem;
@property (nonatomic, assign) int32_t hostWindowId;
@property (nonatomic, assign) int32_t inspectorSlotId;   // inspector webview's slot
@property (nonatomic, assign) NSInteger inspectorDividerIndex;  // divider before the trailing item
@property (nonatomic, assign) BOOL lastCollapsed;
@property (nonatomic, assign) int lastWidth;
@end

static NSMutableDictionary<NSValue*, ZappInspectorController*>* zapp_inspectors = nil;

static void zapp_inspector_on_main(void (^block)(void)) {
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

// slot -> owning NSWindow -> registry key. Works from any pane's slot.
static ZappInspectorController* zapp_inspector_for_slot(int32_t slot_id) {
    if (!zapp_inspectors) return nil;
    void* win_ptr = darwin_window_get_by_numeric_id(slot_id);
    if (!win_ptr) return nil;
    return zapp_inspectors[[NSValue valueWithPointer:win_ptr]];
}

static int zapp_inspector_current_width(ZappInspectorController* c) {
    if (!c || !c.inspectorItem) return 0;
    NSView* v = c.inspectorItem.viewController.view;
    if (!v) return 0;
    return (int)lround(v.frame.size.width);
}

static void zapp_inspector_emit(ZappInspectorController* c, const char* eventName, NSString* dataJson) {
    if (!c) return;
    zapp_pane_emit(c.hostWindowId, c.inspectorSlotId, eventName, dataJson);
}

static void zapp_inspector_sync_collapse(ZappInspectorController* c) {
    if (!c || !c.inspectorItem) return;
    BOOL collapsed = c.inspectorItem.isCollapsed;
    if (collapsed == c.lastCollapsed) return;
    c.lastCollapsed = collapsed;
    zapp_inspector_emit(c, collapsed ? "inspector-collapsed" : "inspector-expanded", nil);
}

@implementation ZappInspectorController
- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object
                        change:(NSDictionary*)change context:(void*)context {
    if ([keyPath isEqualToString:@"collapsed"]) zapp_inspector_sync_collapse(self);
}
- (void)splitViewDidResize:(NSNotification*)note {
    zapp_inspector_sync_collapse(self);
    if (self.inspectorItem.isCollapsed) return;
    int w = zapp_inspector_current_width(self);
    if (w <= 0 || w == self.lastWidth) return;
    self.lastWidth = w;
    NSString* json = [NSString stringWithFormat:@"{\"width\":%d}", w];
    zapp_inspector_emit(self, "inspector-resized", json);
}
@end

// --- Control ops (router entry points) ---

void darwin_inspector_toggle(int32_t window_id) {
    zapp_inspector_on_main(^{
        ZappInspectorController* c = zapp_inspector_for_slot(window_id);
        if (!c || !c.inspectorItem) return;
        [[c.inspectorItem animator] setCollapsed:!c.inspectorItem.isCollapsed];
    });
}

void darwin_inspector_collapse(int32_t window_id) {
    zapp_inspector_on_main(^{
        ZappInspectorController* c = zapp_inspector_for_slot(window_id);
        if (!c || !c.inspectorItem) return;
        if (c.inspectorItem.isCollapsed) return; // idempotent
        [[c.inspectorItem animator] setCollapsed:YES];
    });
}

void darwin_inspector_expand(int32_t window_id) {
    zapp_inspector_on_main(^{
        ZappInspectorController* c = zapp_inspector_for_slot(window_id);
        if (!c || !c.inspectorItem) return;
        if (!c.inspectorItem.isCollapsed) return; // idempotent
        [[c.inspectorItem animator] setCollapsed:NO];
    });
}

void darwin_inspector_set_width(int32_t window_id, int32_t width) {
    zapp_inspector_on_main(^{
        ZappInspectorController* c = zapp_inspector_for_slot(window_id);
        if (!c || !c.inspectorItem || !c.splitVC) return;
        CGFloat w = (CGFloat)width;
        CGFloat minT = c.inspectorItem.minimumThickness;
        CGFloat maxT = c.inspectorItem.maximumThickness;
        if (minT > 0 && w < minT) w = minT;
        if (maxT > 0 && w > maxT) w = maxT;
        // Trailing pane: the divider's x is measured from the left, so set it
        // to (total width − inspector width).
        CGFloat total = c.splitVC.splitView.bounds.size.width;
        [c.splitVC.splitView setPosition:(total - w) ofDividerAtIndex:c.inspectorDividerIndex];
    });
}

// --- Registry (called from window.m construction / teardown) ---

void zapp_inspector_register(void* window_ptr, void* splitVCp, void* inspectorItemp,
                             int32_t host_id, int32_t inspector_slot_id) {
    if (!window_ptr || !splitVCp || !inspectorItemp) return;
    zapp_inspector_on_main(^{
        if (!zapp_inspectors) zapp_inspectors = [NSMutableDictionary dictionary];
        NSValue* key = [NSValue valueWithPointer:window_ptr];
        NSSplitViewController* splitVC = (__bridge NSSplitViewController*)splitVCp;
        NSSplitViewItem* inspectorItem = (__bridge NSSplitViewItem*)inspectorItemp;

        ZappInspectorController* c = [[ZappInspectorController alloc] init];
        c.splitVC = splitVC;
        c.inspectorItem = inspectorItem;
        c.hostWindowId = host_id;
        c.inspectorSlotId = inspector_slot_id;
        // Inspector is the trailing item; the divider that resizes it is the
        // one immediately before it.
        c.inspectorDividerIndex = [splitVC.splitViewItems indexOfObject:inspectorItem] - 1;
        c.lastCollapsed = inspectorItem.isCollapsed;
        c.lastWidth = zapp_inspector_current_width(c);

        [inspectorItem addObserver:c forKeyPath:@"collapsed"
                           options:NSKeyValueObservingOptionNew context:NULL];
        [[NSNotificationCenter defaultCenter]
            addObserver:c selector:@selector(splitViewDidResize:)
                   name:NSSplitViewDidResizeSubviewsNotification
                 object:splitVC.splitView];

        zapp_inspectors[key] = c;
    });
}

void zapp_inspector_unregister(void* window_ptr) {
    if (!window_ptr) return;
    zapp_inspector_on_main(^{
        if (!zapp_inspectors) return;
        NSValue* key = [NSValue valueWithPointer:window_ptr];
        ZappInspectorController* c = zapp_inspectors[key];
        if (!c) return;
        @try { [c.inspectorItem removeObserver:c forKeyPath:@"collapsed"]; }
        @catch (__unused NSException* e) {}
        [[NSNotificationCenter defaultCenter] removeObserver:c];
        [zapp_inspectors removeObjectForKey:key];
    });
}

// Divider index of the inspector for a window, or -1 if none. Used by
// toolbar.m to point an inspector trackingSeparator at the right divider.
int32_t zapp_inspector_divider_index(void* window_ptr) {
    if (!window_ptr || !zapp_inspectors) return -1;
    ZappInspectorController* c = zapp_inspectors[[NSValue valueWithPointer:window_ptr]];
    if (!c) return -1;
    return (int32_t)c.inspectorDividerIndex;
}
```

- [ ] **Step 3: Create `native/platform/ios/inspector.m` (stubs)**

```objc
// iOS stubs — NSSplitViewController is AppKit-only. The router references the
// four control symbols under #ifdef __APPLE__ (true on iOS), so they must
// exist; window.m/toolbar.m registry symbols are macOS-only (darwin/ twins
// not compiled on iOS) and are not stubbed here.
#include <stdint.h>

void darwin_inspector_toggle(int32_t window_id) { (void)window_id; }
void darwin_inspector_collapse(int32_t window_id) { (void)window_id; }
void darwin_inspector_expand(int32_t window_id) { (void)window_id; }
void darwin_inspector_set_width(int32_t window_id, int32_t width) { (void)window_id; (void)width; }
```

- [ ] **Step 4: Register the source files**

In `cli/src/native.ts`, the darwin list (after `path.join(darwinDir, "sidebar.m"),` ~line 64):

```ts
      path.join(darwinDir, "inspector.m"),
```

The iOS list (after `path.join(iosDir, "sidebar.m"),` ~line 98):

```ts
      path.join(iosDir, "inspector.m"),
```

- [ ] **Step 5: Build both platforms (compile + link gate — symbols defined, uncalled)**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build
cd /Users/zach/code/zapp/hello-world && bun run build --platform ios-simulator
```
Expected: each ends `[zapp] build complete: <path>`.

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add native/platform/darwin/sidebar.m native/platform/darwin/inspector.m native/platform/ios/inspector.m cli/src/native.ts
git commit -m "$(cat <<'EOF'
feat(native): inspector.m controller + registry + control ops (+ iOS stubs)

Parallel to sidebar.m: ZappInspectorController registry keyed by host
window, darwin_inspector_toggle/collapse/expand/set_width (trailing-pane
divider math), zapp_inspector_register/unregister, zapp_inspector_divider
_index for toolbar tracking. Shared zapp_pane_emit extracted from
sidebar.m (behavior-preserving). iOS no-op stubs; both files registered
in the native source lists.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Native — `webview.m` composition flags + `pane_role 3` marker

**Files:**
- Modify: `native/platform/darwin/webview.m`
- Modify: `native/platform/darwin/popover.m`

The `hasSidebar` marker is injected via the heuristic `container_view != NULL && pane_role != 2`, which wrongly fires for inspector-only windows (they also mount via `container_view`). Replace the heuristic with explicit composition flags and add the inspector pane marker. Behavior is unchanged for existing windows.

- [ ] **Step 1: Extend `darwin_webview_create_ext`'s signature**

In `native/platform/darwin/webview.m`, the definition (~line 787) gains two params at the end:

```objc
void darwin_webview_create_ext(void* window_ptr, bool inspectable, bool accept_first_mouse,
                               const char* url_override, int32_t numeric_id_pre_alloc,
                               bool transparent_background,
                               void* container_view /* NSView*; NULL = legacy mount */,
                               int32_t identity_window_id /* -1 = self identity */,
                               int32_t pane_role,
                               bool host_has_sidebar,
                               bool host_has_inspector) {
```

- [ ] **Step 2: Add the inspector marker + replace the hasSidebar heuristic**

Find the pane-role marker block (~lines 920-940). The current code is:

```objc
    if (pane_role == 1) {
        [ucc addUserScript:[[WKUserScript alloc] initWithSource:
            @"(function(){globalThis[Symbol.for('zapp.isSidebar')]=true;})();"
            injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    } else if (pane_role == 2) {
        [ucc addUserScript:[[WKUserScript alloc] initWithSource:
            @"(function(){globalThis[Symbol.for('zapp.isPopover')]=true;})();"
            injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    }
    // 3c. hasSidebar marker — set in BOTH panes of a split window (only
    //     sidebar windows mount via container_view), so Window.current()
    //     ... [existing comment] ...
    if (container_view != NULL && pane_role != 2) {
        [ucc addUserScript:[[WKUserScript alloc] initWithSource:
            @"(function(){globalThis[Symbol.for('zapp.hasSidebar')]=true;})();"
            injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    }
```

Replace that whole region with:

```objc
    if (pane_role == 1) {
        [ucc addUserScript:[[WKUserScript alloc] initWithSource:
            @"(function(){globalThis[Symbol.for('zapp.isSidebar')]=true;})();"
            injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    } else if (pane_role == 2) {
        [ucc addUserScript:[[WKUserScript alloc] initWithSource:
            @"(function(){globalThis[Symbol.for('zapp.isPopover')]=true;})();"
            injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    } else if (pane_role == 3) {
        [ucc addUserScript:[[WKUserScript alloc] initWithSource:
            @"(function(){globalThis[Symbol.for('zapp.isInspector')]=true;})();"
            injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    }
    // has{Sidebar,Inspector} markers — injected into every pane of a window
    // that has the corresponding accessory, so Window.current() in ANY pane
    // wires the matching handle. Driven by explicit composition flags (the
    // old container_view heuristic mis-fired for inspector-only windows).
    if (host_has_sidebar) {
        [ucc addUserScript:[[WKUserScript alloc] initWithSource:
            @"(function(){globalThis[Symbol.for('zapp.hasSidebar')]=true;})();"
            injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    }
    if (host_has_inspector) {
        [ucc addUserScript:[[WKUserScript alloc] initWithSource:
            @"(function(){globalThis[Symbol.for('zapp.hasInspector')]=true;})();"
            injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    }
```

Also update the `pane_role` doc comment block (~lines 767-775) to mention `3 = inspector pane (sets zapp.isInspector)` and the two new flags.

- [ ] **Step 3: Update the thin `darwin_webview_create` wrapper**

The wrapper (~line 1132) calls `create_ext` with defaults. Add `false, false`:

```objc
void darwin_webview_create(void* window_ptr, bool inspectable, bool accept_first_mouse,
                           const char* url_override, int32_t numeric_id_pre_alloc, bool transparent_background) {
    darwin_webview_create_ext(window_ptr, inspectable, accept_first_mouse, url_override,
                              numeric_id_pre_alloc, transparent_background, NULL, -1, 0, false, false);
}
```

(Match the existing argument list; only the trailing `, false, false` is new — verify against the actual current call and append the two flags.)

- [ ] **Step 4: Update the existing window.m sidebar-branch call sites**

In `native/platform/darwin/window.m`, the two `create_ext` calls in the current sidebar branch (~lines 738-743) gain the two flags. For now (sidebar-only path), pass `useSidebar, false` — Task 6 rewrites this branch fully, but it must compile after Task 5:

- main pane call (~line 738): append `, useSidebar, false` before the closing `)`.
- sidebar pane call (~line 741): append `, useSidebar, false`.

Also update the extern declaration of `darwin_webview_create_ext` at the top of window.m (~line 19) to match the new signature (append `, bool host_has_sidebar, bool host_has_inspector`).

- [ ] **Step 5: Update the popover.m call site**

In `native/platform/darwin/popover.m`: update the extern (~line 15) and the call (~line 79). Popover panes carry no accessory markers — pass `false, false`:

```objc
    darwin_webview_create_ext(window_ptr, true, true, url, popover_slot, true,
                              (__bridge void*)container, host_slot, 2, false, false);
```

And the extern (~line 15) appends `, bool host_has_sidebar, bool host_has_inspector`.

- [ ] **Step 6: Build (behavior-unchanged refactor gate)**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build
cd /Users/zach/code/zapp/hello-world && bun run build --platform ios-simulator
```
Expected: each ends `[zapp] build complete: <path>`. (Existing sidebar windows still get `hasSidebar` via the explicit `useSidebar` flag — same result as the old heuristic.)

- [ ] **Step 7: Commit**

```bash
cd /Users/zach/code/zapp
git add native/platform/darwin/webview.m native/platform/darwin/window.m native/platform/darwin/popover.m
git commit -m "$(cat <<'EOF'
refactor(native): explicit pane composition flags in create_ext

darwin_webview_create_ext gains host_has_sidebar/host_has_inspector and a
pane_role 3 → zapp.isInspector marker. The has{Sidebar,Inspector} markers
are now driven by explicit flags instead of the container_view heuristic
(which mis-fired for inspector-only windows). Behavior unchanged for
existing windows. All four call sites updated.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Native — `window.m` generalized split builder (inspector pane)

**Files:**
- Modify: `native/platform/darwin/window.m`

Generalize the construction so a window roots on the split controller when it has a sidebar AND/OR an inspector, mounting each requested accessory pane. This is the integration task — after it, a create-time inspector renders.

- [ ] **Step 1: Add the extern declarations**

Near the other `extern` decls at the top of `window.m` (where `zapp_sidebar_register`/`zapp_sidebar_unregister` are, ~lines 27-29), add:

```objc
extern void zapp_inspector_register(void* window_ptr, void* splitVC, void* inspectorItem,
                                    int32_t host_id, int32_t inspector_slot_id);
extern void zapp_inspector_unregister(void* window_ptr);
extern const char* wopts_inspector_url(void* opts);
extern const char* wopts_inspector_material(void* opts);
extern int32_t wopts_inspector_width(void* opts);
extern int32_t wopts_inspector_min_width(void* opts);
extern int32_t wopts_inspector_max_width(void* opts);
extern bool wopts_inspector_collapsible(void* opts);
extern bool wopts_inspector_collapsed(void* opts);
extern int32_t wopts_inspector_numeric_id(void* opts);
```

- [ ] **Step 2: Add the inspector slot table (mirror the sidebar table)**

Find the sidebar slot table in `window.m` (`zapp_sidebar_slot_of[]`, `zapp_set_sidebar_slot`, `zapp_sidebar_slot_for`, `zapp_sidebar_slot_lookup`, ~lines 80-136). Add the inspector twin immediately after it:

```objc
// host slot -> inspector slot, for window-event fan-out. -1 = no inspector.
static int32_t zapp_inspector_slot_of[ZAPP_MAX_WINDOW_CALLBACKS];
static bool zapp_inspector_slot_of_init = false;

static void zapp_set_inspector_slot(int32_t host_slot, int32_t inspector_slot) {
    if (!zapp_inspector_slot_of_init) {
        for (int i = 0; i < ZAPP_MAX_WINDOW_CALLBACKS; i++) zapp_inspector_slot_of[i] = -1;
        zapp_inspector_slot_of_init = true;
    }
    if (host_slot >= 0 && host_slot < ZAPP_MAX_WINDOW_CALLBACKS) {
        zapp_inspector_slot_of[host_slot] = inspector_slot;
    }
}

static int32_t zapp_inspector_slot_for(int32_t host_slot) {
    if (!zapp_inspector_slot_of_init) return -1;
    if (host_slot < 0 || host_slot >= ZAPP_MAX_WINDOW_CALLBACKS) return -1;
    return zapp_inspector_slot_of[host_slot];
}

int32_t zapp_inspector_slot_lookup(int32_t host_slot) {
    return zapp_inspector_slot_for(host_slot);
}
```

(Match the exact guards/shape of the sidebar versions you find — replicate them with the inspector names.)

- [ ] **Step 3: Extend the window-event fan-out**

In `zapp_dispatch_event_to_js` (the sidebar fan-out block, ~lines 220-226), add the inspector twin right after the sidebar fan-out:

```objc
    int32_t inspector_slot = zapp_inspector_slot_for(window_id);
    if (inspector_slot >= 0 && inspector_slot != window_id &&
        inspector_slot < ZAPP_MAX_WINDOW_CALLBACKS) {
        WKWebView* inspectorWebview = zapp_webviews[inspector_slot];
        if (inspectorWebview) {
            [inspectorWebview evaluateJavaScript:js completionHandler:nil];
        }
    }
```

- [ ] **Step 4: Generalize the construction branch**

Replace the current `if (useSidebar) { … }` branch (~lines 661-777) with the generalized builder below. (The `else if (useVibrancy)` branch that follows at ~line 778 stays unchanged — it handles plain non-split windows.)

```objc
        const char* inspectorUrl = wopts_inspector_url(opts);
        bool useInspector = (inspectorUrl && inspectorUrl[0] != '\0');
        int32_t inspector_slot = wopts_inspector_numeric_id(opts);

        WKWebView* inspectorWebviewRef = nil;

        if (useSidebar || useInspector) {
            // Pane windows root on an NSSplitViewController (the split must be
            // the window's root BEFORE any webview loads — re-parenting a
            // WKWebView resets its content process and breaks the bridge). All
            // panes are born in their final containers, never re-parented.
            if (tbs == 0) {
                [window setStyleMask:([window styleMask] | NSWindowStyleMaskFullSizeContentView)];
                [window setTitleVisibility:NSWindowTitleHidden];
                [window setTitlebarAppearsTransparent:YES];
            }

            // Content pane (always present). Vibrancy wraps the MAIN pane only.
            NSViewController* contentVC = [[NSViewController alloc] init];
            contentVC.view = [[NSView alloc] initWithFrame:[window contentView].frame];
            NSView* mainContainer = contentVC.view;
            if (useVibrancy) {
                NSVisualEffectView* vfx = [[NSVisualEffectView alloc] initWithFrame:contentVC.view.frame];
                vfx.material = material;
                vfx.blendingMode = NSVisualEffectBlendingModeBehindWindow;
                vfx.state = NSVisualEffectStateFollowsWindowActiveState;
                vfx.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
                contentVC.view = vfx;
                mainContainer = vfx;
            }

            NSSplitViewController* splitVC = [[NSSplitViewController alloc] init];

            // Leading sidebar pane (optional).
            NSSplitViewItem* sideItem = nil;
            NSView* sidebarContainer = nil;
            if (useSidebar) {
                NSViewController* sideVC = [[NSViewController alloc] init];
                sideVC.view = [[NSView alloc] initWithFrame:
                    NSMakeRect(0, 0, (CGFloat)wopts_sidebar_width(opts), (CGFloat)wopts_height(opts))];
                sidebarContainer = sideVC.view;
                const char* sidebarMaterialName = wopts_sidebar_material(opts);
                bool sidebarMaterialOverride = sidebarMaterialName && sidebarMaterialName[0] != '\0' &&
                                               strcmp(sidebarMaterialName, "sidebar") != 0;
                if (sidebarMaterialOverride) {
                    NSVisualEffectView* svfx = [[NSVisualEffectView alloc] initWithFrame:sideVC.view.bounds];
                    svfx.material = zapp_material_from_name(sidebarMaterialName);
                    svfx.blendingMode = NSVisualEffectBlendingModeBehindWindow;
                    svfx.state = NSVisualEffectStateFollowsWindowActiveState;
                    svfx.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
                    sideVC.view = svfx;
                    sidebarContainer = svfx;
                }
                sideItem = [NSSplitViewItem sidebarWithViewController:sideVC];
                sideItem.minimumThickness = (CGFloat)wopts_sidebar_min_width(opts);
                sideItem.maximumThickness = (CGFloat)wopts_sidebar_max_width(opts);
                sideItem.canCollapse = wopts_sidebar_collapsible(opts);
                [splitVC addSplitViewItem:sideItem];
            }

            // Content pane.
            NSSplitViewItem* contentItem = [NSSplitViewItem splitViewItemWithViewController:contentVC];
            [splitVC addSplitViewItem:contentItem];

            // Trailing inspector pane (optional).
            NSSplitViewItem* inspItem = nil;
            NSView* inspectorContainer = nil;
            if (useInspector) {
                NSViewController* inspVC = [[NSViewController alloc] init];
                inspVC.view = [[NSView alloc] initWithFrame:
                    NSMakeRect(0, 0, (CGFloat)wopts_inspector_width(opts), (CGFloat)wopts_height(opts))];
                inspectorContainer = inspVC.view;
                const char* inspectorMaterialName = wopts_inspector_material(opts);
                bool inspectorMaterialOverride = inspectorMaterialName && inspectorMaterialName[0] != '\0' &&
                                                 strcmp(inspectorMaterialName, "sidebar") != 0;
                if (inspectorMaterialOverride) {
                    NSVisualEffectView* ivfx = [[NSVisualEffectView alloc] initWithFrame:inspVC.view.bounds];
                    ivfx.material = zapp_material_from_name(inspectorMaterialName);
                    ivfx.blendingMode = NSVisualEffectBlendingModeBehindWindow;
                    ivfx.state = NSVisualEffectStateFollowsWindowActiveState;
                    ivfx.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
                    inspVC.view = ivfx;
                    inspectorContainer = ivfx;
                }
                if (@available(macOS 11.0, *)) {
                    inspItem = [NSSplitViewItem inspectorWithViewController:inspVC];
                } else {
                    inspItem = [NSSplitViewItem splitViewItemWithViewController:inspVC];
                }
                inspItem.minimumThickness = (CGFloat)wopts_inspector_min_width(opts);
                inspItem.maximumThickness = (CGFloat)wopts_inspector_max_width(opts);
                inspItem.canCollapse = wopts_inspector_collapsible(opts);
                [splitVC addSplitViewItem:inspItem];
            }

            window.contentViewController = splitVC;

            // Initial geometry (controller is now the root). Sidebar divider
            // is index 0; the inspector divider is the one before the trailing
            // item, positioned from the left as (total − inspectorWidth).
            if (useSidebar) {
                [splitVC.splitView setPosition:(CGFloat)wopts_sidebar_width(opts) ofDividerAtIndex:0];
                if (wopts_sidebar_collapsed(opts)) sideItem.collapsed = YES;
            }
            if (useInspector) {
                NSInteger inspDivider = (NSInteger)splitVC.splitViewItems.count - 2;
                CGFloat totalW = splitVC.splitView.bounds.size.width;
                [splitVC.splitView setPosition:(totalW - (CGFloat)wopts_inspector_width(opts))
                                ofDividerAtIndex:inspDivider];
                if (wopts_inspector_collapsed(opts)) inspItem.collapsed = YES;
            }

            // Webviews. Main → host slot, self identity, pane_role 0. Sidebar →
            // sidebar slot, host identity, pane_role 1. Inspector → inspector
            // slot, host identity, always-transparent, pane_role 3. has* flags
            // drive the Window.current() handle wiring in every pane.
            darwin_webview_create_ext((__bridge void*)window, inspectable, accept_first_mouse,
                                      custom_url, host_slot, useVibrancy,
                                      (__bridge void*)mainContainer, -1, 0,
                                      useSidebar, useInspector);
            if (useSidebar) {
                darwin_webview_create_ext((__bridge void*)window, inspectable, accept_first_mouse,
                                          sidebarUrl, sidebar_slot, true,
                                          (__bridge void*)sidebarContainer, host_slot, 1,
                                          useSidebar, useInspector);
            }
            if (useInspector) {
                darwin_webview_create_ext((__bridge void*)window, inspectable, accept_first_mouse,
                                          inspectorUrl, inspector_slot, true,
                                          (__bridge void*)inspectorContainer, host_slot, 3,
                                          useSidebar, useInspector);
            }

            // Register webviews in the dispatch table (contentView is the
            // NSSplitView, so the auto-registration walk can't find them).
            NSString* hostWindowId = [NSString stringWithFormat:@"win-%d", host_slot];
            for (NSView* sub in mainContainer.subviews) {
                if ([sub isKindOfClass:[WKWebView class]]) {
                    mainWebviewRef = (WKWebView*)sub;
                    zapp_register_webview(host_slot, mainWebviewRef, hostWindowId);
                    break;
                }
            }
            if (useSidebar) {
                for (NSView* sub in sidebarContainer.subviews) {
                    if ([sub isKindOfClass:[WKWebView class]]) { sidebarWebviewRef = (WKWebView*)sub; break; }
                }
                if (sidebarWebviewRef) zapp_register_webview(sidebar_slot, sidebarWebviewRef, hostWindowId);
            }
            if (useInspector) {
                for (NSView* sub in inspectorContainer.subviews) {
                    if ([sub isKindOfClass:[WKWebView class]]) { inspectorWebviewRef = (WKWebView*)sub; break; }
                }
                if (inspectorWebviewRef) zapp_register_webview(inspector_slot, inspectorWebviewRef, hostWindowId);
            }

            // Fan-out tables + accessory registries.
            if (useSidebar) {
                zapp_set_sidebar_slot(host_slot, sidebar_slot);
                zapp_sidebar_register((__bridge void*)window, (__bridge void*)splitVC,
                                      (__bridge void*)sideItem, host_slot, sidebar_slot);
            }
            if (useInspector) {
                zapp_set_inspector_slot(host_slot, inspector_slot);
                zapp_inspector_register((__bridge void*)window, (__bridge void*)splitVC,
                                        (__bridge void*)inspItem, host_slot, inspector_slot);
            }
        } else if (useVibrancy) {
```

(The trailing `} else if (useVibrancy) {` line replaces the original branch's `} else if (useVibrancy) {` — keep the vibrancy branch body that follows unchanged.)

- [ ] **Step 5: Teardown**

In `windowWillClose:` (where `zapp_sidebar_unregister(handle)` and `zapp_toolbar_unregister(handle)` are called, ~lines 904-906), add:

```objc
    zapp_inspector_unregister(handle);
```

(Place it alongside the sidebar/toolbar unregisters. The `handle` is the window pointer used there.)

- [ ] **Step 6: Build both platforms**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build
cd /Users/zach/code/zapp/hello-world && bun run build --platform ios-simulator
```
Expected: each ends `[zapp] build complete: <path>`.

- [ ] **Step 7: Commit**

```bash
cd /Users/zach/code/zapp
git add native/platform/darwin/window.m
git commit -m "$(cat <<'EOF'
feat(native): window.m generalized split builder — inspector pane

The split branch now assembles 1-3 panes ([sidebar?], content,
[inspector?]); inspector mounts a trailing inspectorWithViewController:
item (pane_role 3) with its own slot, divider geometry, dispatch-table
registration, event fan-out table, and zapp_inspector_register. Teardown
unregisters the inspector. Sidebar-only windows behave identically.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Router — `inspector:*` action block

**Files:**
- Modify: `native/app/router.zc`

- [ ] **Step 1: Add the action block**

Insert into `router_handle_window_action` directly after the `sidebar:*` block's closing `return; }` (~line 727) and before the popover block. It is a verbatim clone of the sidebar block with `inspector` names:

```zc
    let is_in_toggle = action == "inspector:toggle";
    let is_in_collapse = action == "inspector:collapse";
    let is_in_expand = action == "inspector:expand";
    let is_in_set_width = action == "inspector:setWidth";
    if is_in_toggle || is_in_collapse || is_in_expand || is_in_set_width {
        let in_target = window_id;
        let in_wid_opt = pre_args.get_string("windowId");
        if in_wid_opt.is_some() {
            raw {
                #ifdef __APPLE__
                extern int32_t darwin_window_numeric_id_for_string(const char* wid);
                int32_t in_resolved = darwin_window_numeric_id_for_string((const char*)in_wid_opt.val);
                if (in_resolved >= 0) in_target = in_resolved;
                #endif
            }
        }
        let in_w = 0;
        if is_in_set_width {
            let width_opt = pre_args.get_int("width");
            if width_opt.is_some() { in_w = width_opt.unwrap(); }
        }
        raw {
            #ifdef __APPLE__
            extern void darwin_inspector_toggle(int32_t window_id);
            extern void darwin_inspector_collapse(int32_t window_id);
            extern void darwin_inspector_expand(int32_t window_id);
            extern void darwin_inspector_set_width(int32_t window_id, int32_t width);
            if (is_in_toggle) darwin_inspector_toggle((int32_t)in_target);
            else if (is_in_collapse) darwin_inspector_collapse((int32_t)in_target);
            else if (is_in_expand) darwin_inspector_expand((int32_t)in_target);
            else darwin_inspector_set_width((int32_t)in_target, (int32_t)in_w);
            #endif
        }
        return;
    }
```

(`inspector:*` is ungated by design like `sidebar:*` — `permission_id_for_action` already returns `""` for it; no change needed there.)

- [ ] **Step 2: Build both platforms (links the darwin impls + iOS stubs)**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build
cd /Users/zach/code/zapp/hello-world && bun run build --platform ios-simulator
```
Expected: each ends `[zapp] build complete: <path>`.

- [ ] **Step 3: iOS parity test**

Run: `cd /Users/zach/code/zapp && bun test ./cli/src/ios-platform-parity.test.ts`
Expected: PASS — `darwin_inspector_toggle/collapse/expand/set_width` referenced from router.zc are defined in both `native/platform/darwin/inspector.m` and `native/platform/ios/inspector.m`.

- [ ] **Step 4: Commit**

```bash
cd /Users/zach/code/zapp
git add native/app/router.zc
git commit -m "$(cat <<'EOF'
feat(router): inspector:toggle/collapse/expand/setWidth window actions

Verbatim clone of the sidebar:* block — payload-windowId resolution with
sender fallback, Apple-gated, ungated by design. iOS links via the Task-4
stubs.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Native — `toolbar.m` `toggleInspector` + inspector `trackingSeparator`

**Files:**
- Modify: `native/platform/darwin/toolbar.m`

- [ ] **Step 1: Externs + private identifier + selector**

Near the top of `native/platform/darwin/toolbar.m`, alongside the other externs (after `zapp_sidebar_slot_lookup`, ~line 23), add:

```objc
extern void darwin_inspector_toggle(int32_t window_id);
extern int32_t zapp_inspector_divider_index(void* window_ptr);
extern int32_t zapp_inspector_slot_lookup(int32_t host_slot);
```

After `kZappTrackingSeparatorId` (~line 26), add a private identifier for the toggle-inspector item:

```objc
static NSString* const kZappToggleInspectorId = @"zapp.toggleInspector";
```

- [ ] **Step 2: Parse `toggleInspector` in `zapp_toolbar_parse_items`**

In `zapp_toolbar_parse_items`, add a branch alongside `toggleSidebar`/`trackingSeparator` (dedupe like the other system items):

```objc
        } else if ([type isEqualToString:@"toggleInspector"]) {
            if (![ids containsObject:kZappToggleInspectorId])
                [ids addObject:kZappToggleInspectorId];
```

(Insert this `else if` between the `toggleSidebar` and `trackingSeparator` branches.)

- [ ] **Step 3: Build the `toggleInspector` item + handle its click**

In `toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:`, add a branch for `kZappToggleInspectorId` (place it near the `kZappTrackingSeparatorId` branch, before the custom-button lookup):

```objc
    if ([identifier isEqualToString:kZappToggleInspectorId]) {
        NSToolbarItem* item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
        item.label = @"Inspector";
        item.paletteLabel = @"Toggle Inspector";
        item.toolTip = @"Toggle Inspector";
        if (@available(macOS 11.0, *)) {
            item.image = [NSImage imageWithSystemSymbolName:@"sidebar.right"
                          accessibilityDescription:@"Toggle Inspector"];
        }
        item.target = self;
        item.action = @selector(zappToggleInspectorClicked:);
        if (@available(macOS 10.15, *)) item.bordered = YES;
        return item;
    }
```

Add the action method to `@implementation ZappToolbarController` (next to `zappToolbarItemClicked:`):

```objc
- (void)zappToggleInspectorClicked:(NSToolbarItem*)sender {
    (void)sender;
    darwin_inspector_toggle(self.windowNumericId);
}
```

- [ ] **Step 4: Point an inspector `trackingSeparator` at the right divider**

Find the existing `kZappTrackingSeparatorId` branch in `itemForItemIdentifier`. It currently builds an `NSTrackingSeparatorToolbarItem` at `dividerIndex:0`. The reconcile/attach path stores the raw def per identifier; the `trackingSeparator` def now carries `pane`. Resolve the divider from `pane`:

Replace the body of the `kZappTrackingSeparatorId` branch with:

```objc
    if ([identifier isEqualToString:kZappTrackingSeparatorId]) {
        if (@available(macOS 11.0, *)) {
            NSViewController* vc = self.window.contentViewController;
            if ([vc isKindOfClass:[NSSplitViewController class]]) {
                NSSplitView* sv = ((NSSplitViewController*)vc).splitView;
                // pane "inspector" → the content|inspector divider (from the
                // inspector registry); default/"sidebar" → divider 0.
                NSDictionary* def = self.buttonsById[identifier];
                NSString* pane = [def[@"pane"] isKindOfClass:[NSString class]] ? def[@"pane"] : @"sidebar";
                NSInteger dividerIndex = 0;
                if ([pane isEqualToString:@"inspector"]) {
                    int32_t di = zapp_inspector_divider_index((__bridge void*)self.window);
                    if (di < 0) return nil; // no inspector — drop
                    dividerIndex = (NSInteger)di;
                }
                return [NSTrackingSeparatorToolbarItem
                    trackingSeparatorToolbarItemWithIdentifier:identifier
                                                     splitView:sv
                                                  dividerIndex:dividerIndex];
            }
        }
        return nil;
    }
```

For this to work, the `trackingSeparator` def must be stored in `buttonsById` keyed by `kZappTrackingSeparatorId`. In `zapp_toolbar_parse_items`, store it when adding the separator:

```objc
        } else if ([type isEqualToString:@"trackingSeparator"]) {
            if (![ids containsObject:kZappTrackingSeparatorId]) {
                [ids addObject:kZappTrackingSeparatorId];
                buttons[kZappTrackingSeparatorId] = def;  // carries "pane"
            }
```

(Replace the existing `trackingSeparator` branch — which only does the `containsObject` add — with the version above that also stores `def`.)

- [ ] **Step 5: Inject chrome metrics into the inspector pane too**

`zapp_toolbar_inject_metrics` (in toolbar.m) currently pushes `--zapp-titlebar-height`/`--zapp-toolbar-height` into the host + sidebar slots only. Find the slot list (~lines 303-304):

```objc
    int32_t slots[2] = { host_slot, zapp_sidebar_slot_lookup(host_slot) };
    for (int i = 0; i < 2; i++) {
```

Replace with a 3-slot list including the inspector slot:

```objc
    int32_t slots[3] = { host_slot, zapp_sidebar_slot_lookup(host_slot), zapp_inspector_slot_lookup(host_slot) };
    for (int i = 0; i < 3; i++) {
```

(`zapp_inspector_slot_lookup` returns -1 for non-inspector windows; `zapp_webview_for_slot(-1)` already returns nil and is skipped, exactly like the sidebar slot.)

- [ ] **Step 6: Build both platforms**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build
cd /Users/zach/code/zapp/hello-world && bun run build --platform ios-simulator
```
Expected: each ends `[zapp] build complete: <path>`.

- [ ] **Step 7: Commit**

```bash
cd /Users/zach/code/zapp
git add native/platform/darwin/toolbar.m
git commit -m "$(cat <<'EOF'
feat(native): toolbar toggleInspector + inspector trackingSeparator

toggleInspector renders a custom NSToolbarItem (SF symbol sidebar.right)
whose click calls darwin_inspector_toggle. trackingSeparator reads its
"pane" field and tracks the content|inspector divider (resolved via
zapp_inspector_divider_index) when pane == "inspector", else divider 0.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Docs, demo (never committed), full gates

**Files:**
- Modify: `docs/api-reference.md`
- Modify (NEVER COMMIT): `hello-world/src/main.ts`

- [ ] **Step 1: Add the Inspector docs**

In `docs/api-reference.md`, after the Sidebar section (`### Sidebar (native NSSplitViewItem)`, before `### Toolbar (macOS)`), add an Inspector section:

````markdown
### Inspector (macOS)

Pass `inspector` in `Window.create` to attach a trailing utility pane — the
right-hand "inspector" in Mail/Xcode/Notes — completing the
`sidebar | content | inspector` three-column shell. It is a web-content pane
(loads an app route like the sidebar) and mirrors the `SidebarHandle`: declared
at create, toggled/collapsed/resized at runtime. macOS only; the option is a
no-op elsewhere.

```ts
const win = await Window.create({
  url: "/",
  sidebar: { url: "/nav", width: 240 },
  inspector: { url: "/inspector", width: 300, collapsed: true },
  toolbar: {
    items: [
      { type: "toggleSidebar" },
      { type: "trackingSeparator" },                 // tracks the sidebar edge
      { id: "compose", icon: "sf:square.and.pencil", label: "Compose", action: () => {} },
      { type: "flexibleSpace" },
      { type: "trackingSeparator", pane: "inspector" }, // tracks the inspector edge
      { type: "toggleInspector" },                   // toggles the inspector
    ],
  },
});

const insp = Window.current().inspector!;
insp.toggle();
insp.setWidth(360);
win.on(WindowEvent.INSPECTOR_RESIZED, ({ width }) => console.log("inspector", width));
```

**Options:** `url` (required), `width` (default 280), `minWidth`/`maxWidth`
(180/400), `collapsible` (default true), `collapsed` (default false — set true
for the common "hidden until summoned" inspector), `material`.

**Handle (`win.inspector`, present only when the window has one):**
`toggle()` / `collapse()` / `expand()` / `setWidth(px)`, plus `collapsed` and
`width` (tracked from `INSPECTOR_COLLAPSED` / `INSPECTOR_EXPANDED` /
`INSPECTOR_RESIZED`). `Window.isInspector()` is true inside the inspector pane.

**Toolbar integration:** `{ type: "toggleInspector" }` adds a button (SF symbol
`sidebar.right`) that toggles the inspector; `{ type: "trackingSeparator",
pane: "inspector" }` aligns toolbar controls to the content↔inspector divider.
Both require the window to have an inspector (warned + dropped otherwise).

A window with an inspector but no sidebar roots on a 2-item split (content +
inspector); with both, a 3-item split. Each pane consumes one dispatch slot.
````

- [ ] **Step 2: Demo in `hello-world/src/main.ts` (EDIT, NEVER STAGE)**

Read the file first — it has an existing sidebar+toolbar demo window (`lastSidebarWin`). Extend that window's `Window.create` to add an `inspector: { url: <a route or the sidebar route>, width: 300 }`, and add to its toolbar items `{ type: "trackingSeparator", pane: "inspector" }` + `{ type: "toggleInspector" }`. Add page buttons (in the launcher window, calling on the `lastSidebarWin` handle) to prove the gates:

```ts
// --- inspector demo (WIP — never commit) ---
//   "Toggle inspector" → lastSidebarWin?.inspector?.toggle()
//   "Inspector → 360"  → lastSidebarWin?.inspector?.setWidth(360)
// And log events:
//   lastSidebarWin?.on(WindowEvent.INSPECTOR_RESIZED, ({ width }) => console.log("[demo] inspector", width));
//   lastSidebarWin?.on(WindowEvent.INSPECTOR_COLLAPSED, () => console.log("[demo] inspector collapsed"));
```

Pick a route for the inspector pane (reuse the sidebar route or a simple inline one). Note in your report which route you used and what the user should watch.

- [ ] **Step 3: Full test gate**

Run: `cd /Users/zach/code/zapp && bun run test:all`
Expected: all green (bun + native + tsc).

- [ ] **Step 4: Build gates**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build
cd /Users/zach/code/zapp/hello-world && bun run build --platform ios-simulator
```
Expected: each ends `[zapp] build complete: <path>`.

- [ ] **Step 5: Launch smoke (bounded)**

Launch the freshly built macOS binary briefly (background, ~5s, kill), capture stdout/stderr — verify it boots without crashing and without unexpected `[zapp]` warnings. (macOS has no `timeout`; use the python-subprocess pattern.) The user does the visual pass.

- [ ] **Step 6: Commit DOCS ONLY**

```bash
cd /Users/zach/code/zapp
git add docs/api-reference.md
git commit -m "$(cat <<'EOF'
docs(api): inspector pane — win.inspector, toggleInspector, tracking pane

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

Verify with `git status --short` that `hello-world/src/main.ts` is modified-but-unstaged.

---

## Final review checklist (cross-cutting, after all tasks)

- **Wire-name triple-match:** runtime `inspector:toggle|collapse|expand|setWidth` + `{windowId, width?}` ↔ router `pre_args.get_string("windowId")` / `get_int("width")` ↔ `darwin_inspector_*(window_id[, width])`.
- **Marker/handle wiring:** `pane_role 3` → `zapp.isInspector`; `host_has_inspector` → `zapp.hasInspector`; `Window.current()` wires `.inspector` from either marker; `normalizeToolbar(toolbar, hasSidebar, hasInspector)` consistent at both call sites.
- **Divider math:** inspector divider = `splitViewItems.count − 2` (== `indexOfObject:inspectorItem − 1`); `set_width` uses `total − w`; toolbar inspector separator uses `zapp_inspector_divider_index`.
- **Signature parity:** `darwin_inspector_*` four symbols match across `inspector.m`, `ios/inspector.m`, and the router externs.
- **create_ext arity:** all four call sites (legacy wrapper, popover, window.m main/sidebar/inspector) pass the two new bool flags; the window.m extern decl matches.
- **No regression to sidebar:** a sidebar-only window still gets `zapp.hasSidebar`, divider 0 geometry, and `SIDEBAR_*` events (the `zapp_pane_emit` extraction is behavior-preserving; build the sidebar demo to confirm).
- **User-WIP unstaged:** `git status --short hello-world/` shows only unstaged modifications.

## Out of scope (do not build)

Multiple inspectors; bottom/dock pane; dynamic attach to a plain (non-split) window; native-rendered inspector content; Windows/iOS inspector chrome (iOS gets stubs only).
