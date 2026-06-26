# Kitchen-Sink Polish Pass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix seven loose ends in the kitchen-sink demo so each native feature reads clearly and the multi-window demos are focused.

**Architecture:** Demo-only changes in `kitchen-sink/src`. New hash routes go through the single dispatcher `shell/router.ts`; cross-pane state rides the `Events` bus with `windowId` scoping; new sections implement `Section { render, inspector? }` and register in `sections/registry.ts`.

**Tech Stack:** TypeScript + the `@zappdev/runtime` package; Vite-built kitchen-sink; `bun` for check/test/build.

## Global Constraints

- Branch `feat/nim-native`, kept **UNMERGED**.
- Commit trailer on every commit: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- **Staging discipline:** explicit per-file `git add <path>` only. NEVER `git add -A`/`.` (unrelated WIP in the tree). No `git commit --amend`.
- **Always Bun, never Node.** Type-check: `bun run check`. Tests: `bun test`. Build: `cd kitchen-sink && bun run build` (success = a line `[zapp] build complete:`).
- **Demo-only:** NO framework/runtime (`runtime/`, `native/`) changes. If a fix seems to need one, STOP and report (file a follow-up) — do not edit the framework in this cycle.
- Each pane is a separate webview of one window; `Window.current().id` is identical across panes of the same window (used for `windowId`-scoped `Events`).

---

### Task 1: Inspector staleness + popover label (fix existing sections)

**Files:**
- Modify: `kitchen-sink/src/sections/sidebar.ts` (inspector method)
- Modify: `kitchen-sink/src/sections/inspector.ts` (inspector method)
- Modify: `kitchen-sink/src/shell/inspector-pane.ts` (windowId-scope `ks:nav`)
- Modify: `kitchen-sink/src/sections/popover.ts` + `kitchen-sink/src/shell/popover-pane.ts` (label)

**Interfaces:** Consumes existing `Window.current()`, `WindowEvent`, `Events`. No new exports.

- [ ] **Step 1: Root-cause the staleness (no fix yet)**

The Sidebar inspector (`sections/sidebar.ts`) subscribes to `WindowEvent.SIDEBAR_COLLAPSED/EXPANDED/RESIZED` and renders "observing…" until one fires. There is no public getter for current sidebar collapsed/width state (the `collapsed`/`width` fields are create-time `SidebarOptions`, not handle getters). Reproduce: `cd kitchen-sink && bun run dev`, nav to **Sidebar**, then drag the sidebar divider / collapse it, and watch the inspector pane. Two possible findings:
  - (a) It updates on interaction but starts at "observing…" → the complaint is "no initial state shown." Fix = honest live-label (Step 2).
  - (b) It NEVER updates even on collapse/resize → the `SIDEBAR_*` events aren't reaching the inspector pane's webview. That is a **framework delivery gap, OUT OF SCOPE** for this demo cycle — STOP and report it as a follow-up (do not edit `runtime/`/`native/`). Proceed with Steps 2–4 only if (a).

Record which you observed in the report.

- [ ] **Step 2: Reword the Sidebar inspector to an honest live label**

In `sections/sidebar.ts` inspector, replace the static placeholder so it doesn't imply it's already showing state, and keep the live subscriptions:

```ts
  inspector(host) {
    const win = Window.current();
    host.innerHTML = `<div class="kv"><b>Sidebar</b><div data-state class="muted">Live — collapse, expand, or drag the sidebar to see state.</div></div>`;
    const state = host.querySelector<HTMLElement>("[data-state]")!;
    const off = [
      win.on(WindowEvent.SIDEBAR_COLLAPSED, () => { state.textContent = "collapsed"; }),
      win.on(WindowEvent.SIDEBAR_EXPANDED, () => { state.textContent = "expanded"; }),
      win.on(WindowEvent.SIDEBAR_RESIZED, (d: any) => { state.textContent = `width ${d.width}`; }),
    ];
    return () => off.forEach((fn) => fn());
  },
```

- [ ] **Step 3: Same honest label for the Inspector section inspector**

In `sections/inspector.ts` inspector, change the placeholder line to:

```ts
    host.innerHTML = `<div class="kv"><b>Inspector</b><div data-state class="muted">Live — collapse, expand, or drag the inspector to see state.</div></div>`;
```
(Leave its `INSPECTOR_COLLAPSED/EXPANDED/RESIZED` subscriptions unchanged.)

- [ ] **Step 4: windowId-scope the inspector pane's ks:nav (mirror main-pane)**

`shell/inspector-pane.ts` listens to `ks:nav` globally; `main-pane.ts:66` scopes by `windowId`. Mirror it so secondary windows don't cross-drive. In `inspector-pane.ts`, change the `Events.on("ks:nav", ...)` handler to guard:

```ts
  Events.on("ks:nav", ({ id, windowId }: any) => { if (windowId === Window.current().id) show(id); });
```
Ensure `Window` is imported in `inspector-pane.ts` (add `import { Window } from "@zappdev/runtime";` to the existing import if missing).

- [ ] **Step 5: Popover label (item #3 — keep one popover, label it)**

In `sections/popover.ts` the card `intro` (line ~19), make the single-reused-popover intent explicit:
```ts
      intro: "ONE popover, re-anchored on demand — created lazily and reused (the counter inside survives hide/show). Shown here from this button AND from the Compose toolbar item; same popover, two anchors.",
```
In `shell/popover-pane.ts`, add a short line in its rendered content noting "Same popover instance — re-anchored to the button or the Compose toolbar item." (match the file's existing render style; if it builds an innerHTML string, append a `<div class="muted">…</div>`).

- [ ] **Step 6: Gates + commit**

Run `bun run check` (clean) and `cd kitchen-sink && bun run build` (`[zapp] build complete:`).
```bash
cd /Users/zach/code/zapp
git add kitchen-sink/src/sections/sidebar.ts kitchen-sink/src/sections/inspector.ts kitchen-sink/src/shell/inspector-pane.ts kitchen-sink/src/sections/popover.ts kitchen-sink/src/shell/popover-pane.ts
git commit -m "fix(kitchen-sink): honest inspector live-label + windowId-scope inspector nav + popover label

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Window log section (new)

**Files:**
- Create: `kitchen-sink/src/sections/window-log.ts`
- Modify: `kitchen-sink/src/sections/registry.ts` (register it)

**Interfaces:** Produces `export const windowLogSection: Section`.

- [ ] **Step 1: Create the section**

`WindowEvent` exposes (confirmed) `FOCUS`, `BLUR`, `RESIZE`, `MOVE`, and `SCREENS_CHANGED`. Subscribe to those geometry/lifecycle members (if you find additional geometry/lifecycle members like maximize/restore in `runtime/events.ts`, add them; do NOT subscribe to toolbar/sidebar/inspector members — those belong to other sections). Create `kitchen-sink/src/sections/window-log.ts`:

```ts
import { Window, WindowEvent } from "@zappdev/runtime";
import type { Section } from "./types";
import { card } from "../shell/ui";

const MAX = 50;

export const windowLogSection: Section = {
  id: "window-log",
  label: "Window log",
  render(host) {
    host.appendChild(card({
      title: "Window event log",
      intro:
        "A live, scrolling log of this window's geometry + lifecycle events " +
        "(resize, move, focus, blur, display changes). Distinct from the " +
        "Events section (that's the app pub/sub bus). Resize or move this window.",
      buttons: [{ act: "clear", label: "Clear log" }],
    }));
    const log = document.createElement("div");
    log.className = "kv";
    log.style.cssText = "max-height:320px; overflow:auto; font-family:monospace; font-size:12px; line-height:1.5;";
    log.innerHTML = `<div class="muted" data-empty>waiting for events…</div>`;
    host.appendChild(log);

    const append = (label: string, payload: unknown) => {
      log.querySelector("[data-empty]")?.remove();
      const row = document.createElement("div");
      const t = new Date().toLocaleTimeString();
      row.textContent = `${t}  ${label}  ${payload !== undefined ? JSON.stringify(payload) : ""}`.trimEnd();
      log.appendChild(row);
      while (log.childElementCount > MAX) log.firstElementChild!.remove();
      log.scrollTop = log.scrollHeight;
    };

    const win = Window.current();
    const off = [
      win.on(WindowEvent.RESIZE, (d: any) => append("resize", d)),
      win.on(WindowEvent.MOVE, (d: any) => append("move", d)),
      win.on(WindowEvent.FOCUS, () => append("focus", undefined)),
      win.on(WindowEvent.BLUR, () => append("blur", undefined)),
      win.on(WindowEvent.SCREENS_CHANGED, () => append("screens-changed", undefined)),
    ];

    const clear = host.querySelector<HTMLButtonElement>('[data-act="clear"]')!;
    const onClear = () => { log.innerHTML = `<div class="muted" data-empty>waiting for events…</div>`; };
    clear.addEventListener("click", onClear);

    return () => { off.forEach((fn) => fn()); clear.removeEventListener("click", onClear); };
  },
};
```
(Note: this uses `card`'s `buttons` + a manual query for the clear button — mirror how other sections wire buttons; if the repo's `onAct` helper is the convention, use `onAct(host, "clear", onClear)` instead and drop the manual listener.)

- [ ] **Step 2: Register it**

In `kitchen-sink/src/sections/registry.ts`, import `windowLogSection` and add it to the registry array (place it right after the existing `eventsSection` so the two event-related demos sit together).

- [ ] **Step 3: Gates + commit**

`bun run check` (clean), `cd kitchen-sink && bun run build` (`[zapp] build complete:`).
```bash
cd /Users/zach/code/zapp
git add kitchen-sink/src/sections/window-log.ts kitchen-sink/src/sections/registry.ts
git commit -m "feat(kitchen-sink): Window log section — live window geometry/lifecycle events

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Context menu section (new)

**Files:**
- Create: `kitchen-sink/src/sections/contextmenu.ts`
- Modify: `kitchen-sink/src/sections/registry.ts`

**Interfaces:** Produces `export const contextMenuSection: Section`. Consumes `ContextMenu` + `MenuItemDef` from `@zappdev/runtime`.

- [ ] **Step 1: Create the section**

`ContextMenu.show(items, { event })` is the API. Context menus are ephemeral, so `ctx.update` is a no-op there — hold radio/checkbox state in module vars and rebuild the menu on each show (the menu reflects current state on every open). Create `kitchen-sink/src/sections/contextmenu.ts`:

```ts
import { ContextMenu, type MenuItemDef } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, setResult } from "../shell/ui";

// Module state — context menus are rebuilt on each show, so the menu reflects
// these. (ctx.update is a no-op on context menus: they're dismissed on click.)
let sortBy = "name";
let showHidden = false;

function buildMenu(host: HTMLElement): MenuItemDef[] {
  return [
    { id: "cm-new", label: "New Item", action: () => setResult(host, "action: New Item") },
    { id: "cm-dup", label: "Duplicate", action: () => setResult(host, "action: Duplicate") },
    { type: "separator" },
    { id: "cm-sort-name", label: "Sort by Name", radioGroup: "cm-sort", checked: sortBy === "name",
      action: () => { sortBy = "name"; setResult(host, "sort → name"); } },
    { id: "cm-sort-date", label: "Sort by Date", radioGroup: "cm-sort", checked: sortBy === "date",
      action: () => { sortBy = "date"; setResult(host, "sort → date"); } },
    { id: "cm-sort-size", label: "Sort by Size", radioGroup: "cm-sort", checked: sortBy === "size",
      action: () => { sortBy = "size"; setResult(host, "sort → size"); } },
    { type: "separator" },
    { id: "cm-hidden", label: "Show Hidden", type: "checkbox", checked: showHidden,
      action: () => { showHidden = !showHidden; setResult(host, `show hidden → ${showHidden}`); } },
    { type: "separator" },
    { id: "cm-more", label: "More",
      submenu: [
        { id: "cm-export", label: "Export…", action: () => setResult(host, "action: Export") },
        { id: "cm-settings", label: "Settings…", action: () => setResult(host, "action: Settings") },
      ] },
  ];
}

export const contextMenuSection: Section = {
  id: "contextmenu",
  label: "Context menu",
  render(host) {
    host.appendChild(card({
      title: "Context menu (ContextMenu.show)",
      intro:
        "Right-click the area below (or use the button) to open a native context " +
        "menu. It's rebuilt on each show, so the radioGroup checkmark + checkbox " +
        "reflect the current state. Context menus are ephemeral — ctx.update is a " +
        "no-op here; the app holds the state and rebuilds.",
      buttons: [{ act: "show", label: "Show context menu (at button)" }],
    }));

    const target = document.createElement("div");
    target.textContent = "Right-click anywhere in this box";
    target.style.cssText =
      "margin-top:12px; padding:32px; border:1px dashed var(--border,#888); border-radius:10px; text-align:center; user-select:none; opacity:0.85;";
    host.appendChild(target);

    const onCtx = (e: MouseEvent) => { e.preventDefault(); ContextMenu.show(buildMenu(host), { event: e }); };
    target.addEventListener("contextmenu", onCtx);

    const btn = host.querySelector<HTMLButtonElement>('[data-act="show"]')!;
    const onBtn = (e: MouseEvent) => ContextMenu.show(buildMenu(host), { event: e });
    btn.addEventListener("click", onBtn);

    return () => { target.removeEventListener("contextmenu", onCtx); btn.removeEventListener("click", onBtn); };
  },
};
```
(If the repo convention is `onAct(host, "show", …)`, use that for the button instead of the manual listener — but the button handler needs the `MouseEvent` for anchor position, so the manual `addEventListener("click", onBtn)` is preferred here; confirm `ContextMenu.show` falls back to last-pointer position if `event` is absent.)

- [ ] **Step 2: Register it**

In `sections/registry.ts`, import `contextMenuSection` and add it after `popoverSection` (both are transient-UI demos).

- [ ] **Step 3: Gates + commit**

`bun run check`, `cd kitchen-sink && bun run build`.
```bash
cd /Users/zach/code/zapp
git add kitchen-sink/src/sections/contextmenu.ts kitchen-sink/src/sections/registry.ts
git commit -m "feat(kitchen-sink): Context menu section (submenu + radioGroup + checkbox)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Sheets → single pages (item #5)

**Files:**
- Create: `kitchen-sink/src/shell/sheet-pane.ts`
- Modify: `kitchen-sink/src/shell/router.ts` (add `#sheet=` prefix route)
- Modify: `kitchen-sink/src/sections/multiwindow.ts` (3 sheet `Window.create` urls)

**Interfaces:** Produces `export function renderSheetPane(app: HTMLElement)`.

- [ ] **Step 1: Create the sheet pane**

`kitchen-sink/src/shell/sheet-pane.ts` — reads the variant from `#sheet=<variant>` and renders a focused page:

```ts
/** Dedicated single-page content for the sheet demos (page / form / drawer),
 *  instead of falling through to the full kitchen-sink shell. */
export function renderSheetPane(app: HTMLElement) {
  const variant = location.hash.split("=")[1] ?? "settings";
  const wrap = (title: string, body: string) =>
    `<div style="padding:24px; font:14px system-ui; box-sizing:border-box;">
       <h2 style="margin:0 0 12px; font-size:18px;">${title}</h2>${body}</div>`;

  if (variant === "quickadd") {
    app.innerHTML = wrap("Quick Add",
      `<input placeholder="Title" style="display:block;width:100%;padding:8px;margin-bottom:10px;box-sizing:border-box;"/>
       <textarea placeholder="Notes" rows="3" style="display:block;width:100%;padding:8px;box-sizing:border-box;"></textarea>
       <button style="margin-top:12px;padding:8px 14px;">Add</button>`);
    return;
  }
  if (variant === "drawer") {
    app.innerHTML = wrap("Drawer",
      `<ul style="margin:0;padding-left:18px;line-height:1.9;">
         <li>Recent file one</li><li>Recent file two</li><li>Recent file three</li></ul>
       <p style="opacity:0.6;margin-top:14px;">A bottom-sheet drawer with system detents (drag the grabber).</p>`);
    return;
  }
  // settings (default)
  app.innerHTML = wrap("Settings",
    `<label style="display:flex;justify-content:space-between;padding:8px 0;border-bottom:1px solid #8884;">Notifications <input type="checkbox" checked/></label>
     <label style="display:flex;justify-content:space-between;padding:8px 0;border-bottom:1px solid #8884;">Auto-update <input type="checkbox"/></label>
     <label style="display:flex;justify-content:space-between;padding:8px 0;">Theme <select><option>System</option><option>Light</option><option>Dark</option></select></label>`);
}
```

- [ ] **Step 2: Route it**

In `shell/router.ts`, import `renderSheetPane` and add a prefix guard alongside the existing `#bg-demo` guard (before the switch):
```ts
  if (hash.startsWith("#sheet=")) { renderSheetPane(app); return; }
```

- [ ] **Step 3: Point the sheet windows at it**

In `sections/multiwindow.ts`, add `url` to the three sheet `Window.create` calls (the `asSheetOf` ones, ~lines 61/63/65):
- page/Settings → `url: "#sheet=settings"`
- form/Quick Add → `url: "#sheet=quickadd"`
- bottomSheet/Drawer → `url: "#sheet=drawer"`
Keep all other fields (`asSheetOf`, `presentation`, `detents`, `grabber`) unchanged.

- [ ] **Step 4: Gates + commit**

`bun run check`, `cd kitchen-sink && bun run build`.
```bash
cd /Users/zach/code/zapp
git add kitchen-sink/src/shell/sheet-pane.ts kitchen-sink/src/shell/router.ts kitchen-sink/src/sections/multiwindow.ts
git commit -m "feat(kitchen-sink): sheets open dedicated single pages, not the full shell

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Background windows → small sidebar (item #6)

**Files:**
- Modify: `kitchen-sink/src/shell/bg-demo-pane.ts` (2 variants + nav listener + `renderBgSidebarPane`)
- Modify: `kitchen-sink/src/shell/router.ts` (add `#bg-sidebar` case)
- Modify: `kitchen-sink/src/sections/multiwindow.ts` (bg windows' `sidebar.url`)

**Interfaces:** Produces `export function renderBgSidebarPane(app: HTMLElement)`; `renderBgDemoPane` gains a windowId-scoped `ks:bg-nav` listener.

- [ ] **Step 1: Add the 2-item sidebar + variants in `bg-demo-pane.ts`**

Refactor `bg-demo-pane.ts` so the main pane applies a selectable full-bleed background and listens for `ks:bg-nav`, and export a minimal sidebar renderer. Two variants: `aurora` (the existing gradient) and `mesh` (a second multi-stop gradient). Replace the body-background assignment + add the listener:

```ts
import { Events, Window } from "@zappdev/runtime";

const VARIANTS: Record<string, string> = {
  aurora: "linear-gradient(135deg,#aa3bff,#3b82f6,#06b6d4)",
  mesh: "radial-gradient(at 20% 20%,#f472b6,transparent 50%),radial-gradient(at 80% 30%,#facc15,transparent 50%),radial-gradient(at 50% 80%,#22d3ee,transparent 50%),#1e1e2e",
};

function applyVariant(v: string) {
  document.body.style.cssText =
    `margin:0; min-height:100vh; background:${VARIANTS[v] ?? VARIANTS.aurora}`;
}

export function renderBgDemoPane(app: HTMLElement) {
  const raw = location.hash.split("=")[1] ?? "mirror";
  const mode = raw === "extend" ? "extend" : "mirror";
  applyVariant("aurora");
  // ... existing card markup (mode/desc) unchanged ...
  // After building app.innerHTML, listen for the small sidebar's nav (windowId-scoped):
  Events.on("ks:bg-nav", ({ variant, windowId }: any) => {
    if (windowId === Window.current().id) applyVariant(variant);
  });
}

/** Minimal 2-item sidebar for the bg-extension demo windows. */
export function renderBgSidebarPane(app: HTMLElement) {
  document.documentElement.style.background = "transparent";
  document.body.style.background = "transparent";
  app.innerHTML = `
    <div class="sidebar-pane">
      <div class="sidebar-title">BACKGROUND</div>
      <nav>
        <button class="nav-item active" data-v="aurora">Aurora</button>
        <button class="nav-item" data-v="mesh">Mesh</button>
      </nav>
    </div>`;
  const items = app.querySelectorAll<HTMLButtonElement>(".nav-item");
  items.forEach((el) => el.addEventListener("click", () => {
    items.forEach((i) => i.classList.toggle("active", i === el));
    Events.emit("ks:bg-nav", { variant: el.dataset.v!, windowId: Window.current().id });
  }));
}
```
Preserve the existing card markup (the `mode`/`desc` block) — only the body-background line becomes `applyVariant("aurora")` and the `ks:bg-nav` listener is added. Keep the file's existing imports + add `Events, Window`.

- [ ] **Step 2: Route `#bg-sidebar`**

In `shell/router.ts`, import `renderBgSidebarPane` and add a switch case:
```ts
    case "#bg-sidebar": renderBgSidebarPane(app); break;
```

- [ ] **Step 3: Point the bg windows at the small sidebar**

In `sections/multiwindow.ts`, in the `bg-mirror` and `bg-extend` `Window.create` calls (~lines 82/91), change `sidebar: { url: "#sidebar-pane", width: 240 }` → `sidebar: { url: "#bg-sidebar", width: 200 }`.

- [ ] **Step 4: Gates + commit**

`bun run check`, `cd kitchen-sink && bun run build`.
```bash
cd /Users/zach/code/zapp
git add kitchen-sink/src/shell/bg-demo-pane.ts kitchen-sink/src/shell/router.ts kitchen-sink/src/sections/multiwindow.ts
git commit -m "feat(kitchen-sink): bg-extension windows get a 2-item sidebar (Aurora/Mesh)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Color window → text sidebar + focused content (item #7)

**Files:**
- Create: `kitchen-sink/src/shell/color-panes.ts` (`renderColorSidebarPane` + `renderColorContentPane`)
- Modify: `kitchen-sink/src/shell/router.ts` (2 cases)
- Modify: `kitchen-sink/src/sections/multiwindow.ts` (color window urls)

**Interfaces:** Produces `export function renderColorSidebarPane(app)` + `export function renderColorContentPane(app)`.

- [ ] **Step 1: Create the color panes**

`kitchen-sink/src/shell/color-panes.ts`:

```ts
/** The color-demo window's two panes: a descriptive (no-nav) sidebar and a
 *  focused content page explaining the backgroundColor API. */
export function renderColorSidebarPane(app: HTMLElement) {
  document.documentElement.style.background = "transparent";
  document.body.style.background = "transparent";
  app.innerHTML = `
    <div class="sidebar-pane">
      <div class="sidebar-title">COLOR</div>
      <div style="padding:8px 4px; font:13px system-ui; line-height:1.6; opacity:0.92;">
        This sidebar's <code>backgroundColor</code> is a translucent
        <b>rgba(170,59,255,0.4)</b> — the window's opaque <b>teal</b> shows
        through it. No nav items here; it's a pure color demo.
      </div>
    </div>`;
}

export function renderColorContentPane(app: HTMLElement) {
  app.innerHTML = `
    <div style="padding:28px; font:14px system-ui; line-height:1.7; max-width:520px;">
      <h2 style="margin:0 0 12px;">Window background color</h2>
      <p>This window's <code>backgroundColor</code> is the CSS name <b>"teal"</b> (opaque).
         The translucent sidebar lets it show through.</p>
      <p><code>backgroundColor</code> accepts:</p>
      <ul style="line-height:1.9;">
        <li>CSS names — <code>teal</code>, <code>rebeccapurple</code></li>
        <li>hex — <code>#1e1e1e</code>, <code>#aa3bffcc</code></li>
        <li><code>rgb(0, 128, 128)</code> / <code>rgba(170, 59, 255, 0.4)</code></li>
      </ul>
      <p style="opacity:0.6;">Resize the window — the color fills any pre-render / resize gap.</p>
    </div>`;
}
```

- [ ] **Step 2: Route both**

In `shell/router.ts`, import both and add switch cases:
```ts
    case "#color-sidebar": renderColorSidebarPane(app); break;
    case "#color-content": renderColorContentPane(app); break;
```

- [ ] **Step 3: Point the color window at them**

In `sections/multiwindow.ts`, the color-demo `Window.create` (~line 103): set the main `url: "#color-content"` and change `sidebar.url` from `#sidebar-pane` → `#color-sidebar` (keep `backgroundColor: "teal"`, `titleBarStyle: "hiddenInset"`, the sidebar's translucent `backgroundColor`, width).

- [ ] **Step 4: Gates + commit**

`bun run check`, `cd kitchen-sink && bun run build`.
```bash
cd /Users/zach/code/zapp
git add kitchen-sink/src/shell/color-panes.ts kitchen-sink/src/shell/router.ts kitchen-sink/src/sections/multiwindow.ts
git commit -m "feat(kitchen-sink): color window — descriptive text sidebar + focused content

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: Final gates + HUMAN VISUAL SMOKE

**Files:** none (verification only).

- [ ] **Step 1: Full gates**

Run: `bun run check` (clean), `bun test` (all pass), `cd kitchen-sink && bun run build` (`[zapp] build complete:`).

- [ ] **Step 2: HUMAN VISUAL GATE**

STOP. Ask the human to run `cd kitchen-sink && bun run dev` and confirm all seven:
1. **Inspector** — Sidebar/Inspector sections' inspector panes show the honest live label and update on collapse/expand/drag (and don't cross-drive other windows).
2. **Window log** — resize/move/focus/blur the window → entries scroll in; Clear works.
3. **Popover** — the label reads clearly that it's one popover shown from the button + Compose item.
4. **Context menu** — right-click the box (and the button) → submenu + "Sort by" radio (checkmark moves across opens) + "Show Hidden" checkbox.
5. **Sheets** — page/form/bottom sheets each show their focused page, not the full shell.
6. **Bg windows** — Mirror/Extend windows show a 2-item sidebar (Aurora/Mesh) that swaps the background; glass effect re-adapts.
7. **Color window** — text-only sidebar (no nav) + focused content page; teal shows through the translucent sidebar.

Do not consider complete until confirmed.

---

## Self-Review

**Spec coverage:** #1→T1 (label + windowId scope + root-cause), #2→T2 (window-log), #3→T1 Step 5 (popover label), #4→T3 (contextmenu), #5→T4 (sheets), #6→T5 (bg sidebar), #7→T6 (color). Router changes (`#sheet=`, `#bg-sidebar`, `#color-sidebar`, `#color-content`) spread across T4/T5/T6. New registry sections (window-log, contextmenu) in T2/T3. Final smoke = T7. ✓

**Placeholder scan:** No TBD/TODO. Each new file has complete code; the "mirror onAct if that's the convention" notes are explicit fallbacks, not gaps. The bg-demo Step 1 says "preserve existing card markup" rather than re-pasting it — that's a modify-in-place instruction with the exact changed lines shown.

**Type consistency:** `renderSheetPane`/`renderBgSidebarPane`/`renderColorSidebarPane`/`renderColorContentPane` names match between their creating task and the router task that imports them. `ks:bg-nav` payload `{ variant, windowId }` consistent between emitter (T5 sidebar) and listener (T5 bg-demo). `windowLogSection`/`contextMenuSection` export names match their registry imports. `WindowEvent.RESIZE/MOVE/FOCUS/BLUR/SCREENS_CHANGED` are the verified enum members.

**Demo-only guard:** T1 Step 1 explicitly routes a framework delivery-gap finding to a follow-up rather than a `runtime/` edit, honoring the spec non-goal.
