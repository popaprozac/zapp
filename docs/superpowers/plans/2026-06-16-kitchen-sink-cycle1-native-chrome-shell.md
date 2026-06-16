# Kitchen-Sink Cycle 1 — Native-Chrome Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the unused `kitchen-sink/` scaffold into a multi-pane native-chrome showcase shell (sidebar + inspector + toolbar panes) driven by a section registry, with five cycle-1 feature sections (sidebar/inspector/toolbar/popover/multi-window) and a `SMOKE.md` checklist.

**Architecture:** One multi-pane native-chrome window; all panes load the **same Vite bundle** branched on `location.hash` (`#sidebar-pane`/`#main-pane`/`#inspector-pane`/`#popover-pane`). The sidebar pane is the nav (emits `ks:nav` over the `Events` bus from a shared section registry); the main pane renders the active section; the inspector pane renders its live detail. The initial window is created with sidebar+inspector opts in `app.zc`; the toolbar is attached from JS.

**Tech Stack:** TypeScript, Vite, `@zappdev/runtime` (Window/Events/Services/WindowEvent), Zen-C (`app.zc`), Bun (build + `bun test`).

**Spec:** `docs/superpowers/specs/2026-06-16-kitchen-sink-cycle1-design.md`

---

## Build & Smoke Reality (read first)

The app source is **build-agnostic**. Two ways to run, both from `kitchen-sink/`:
- **`bun run dev`** → default **zc** native layer → the *full* shell (sidebar/inspector/toolbar/popover/new windows). **This is the smoke driver for every GATE in this plan.**
- **`ZAPP_NATIVE_LANG=nim bun run dev`** → Nim layer → non-chrome works; native chrome is gated on the (future) WindowManager Nim port. **Not used for gating in this plan** — cycle-1 is native chrome, which smokes on zc.

A native build is successful **only** when its last line is `[zapp] build complete: <path>`. Vite's `✓ built in XXms` is NOT success.

## Standing Constraints (non-negotiable)

- **NEVER** `git add -A` / `git add .`. Stage explicit paths only. For this plan, all staged paths live under `kitchen-sink/` (source only) plus this plan doc. **Never** stage `kitchen-sink/bin/ dist/ .zapp/ node_modules/ src/zapp/` (gitignored already) or any other WIP dir (`vendor/`, `hello-world/`, `spikes/`, etc.).
- **Do NOT edit** `native/**` or `runtime/**` — this is an *app*; it consumes the shipped framework. (The one exception: if Task 1's GATE reveals the initial window can't host chrome, STOP and report — a framework fix is a controller decision, not a silent edit here.)
- Commit message trailer's **last line must be EXACTLY**: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Always **Bun**, never Node.

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `kitchen-sink/zapp/app.zc` | initial window created with sidebar+inspector opts | 1 |
| `kitchen-sink/src/main.ts` | entry: branch on `location.hash` → shell router | 1, 3 |
| `kitchen-sink/src/sections/types.ts` | `Section` interface + pure `findSection` | 2 |
| `kitchen-sink/src/sections/types.test.ts` | bun:test for `findSection` | 2 |
| `kitchen-sink/src/sections/registry.ts` | ordered `Section[]` (grows per section task) | 3–7 |
| `kitchen-sink/src/shell/ui.ts` | tiny DOM helpers (card, setResult) | 3 |
| `kitchen-sink/src/shell/toolbar-def.ts` | shared `shellToolbar()` + filter state | 3 |
| `kitchen-sink/src/shell/router.ts` | hash → pane renderer dispatch | 3 |
| `kitchen-sink/src/shell/sidebar-pane.ts` | nav rows from registry → `ks:nav` | 3 |
| `kitchen-sink/src/shell/main-pane.ts` | render active section + attach toolbar | 3 |
| `kitchen-sink/src/shell/inspector-pane.ts` | render active section's inspector | 3 |
| `kitchen-sink/src/shell/popover-pane.ts` | popover web content | 6 |
| `kitchen-sink/src/sections/sidebar.ts` | Sidebar control section | 3 |
| `kitchen-sink/src/sections/inspector.ts` | Inspector control section | 4 |
| `kitchen-sink/src/sections/toolbar.ts` | Toolbar control section | 5 |
| `kitchen-sink/src/sections/popover.ts` | Popover section | 6 |
| `kitchen-sink/src/sections/multiwindow.ts` | Multi-window section (Nim-aware) | 7 |
| `kitchen-sink/src/style.css` | three-pane shell + cards | 3 |
| `kitchen-sink/SMOKE.md` | structured smoke checklist | 8 |

---

## Task 1: Initial-window native-chrome shell + minimal pane router — RISK-FIRST GATE

**Goal:** Prove the *initial* window mounts a native sidebar + inspector on the zc build (the one feasibility risk), with a throwaway-minimal `main.ts` that just labels each pane.

**Files:**
- Modify: `kitchen-sink/zapp/app.zc`
- Modify: `kitchen-sink/src/main.ts`
- Delete: `kitchen-sink/src/counter.ts`

- [ ] **Step 1: Set initial-window chrome opts in `app.zc`**

Replace `kitchen-sink/zapp/app.zc` with:
```rust
import "app/app.zc";

fn greet(_app: App*, _args: JsonValue*) -> string {
    return "Hello from Zapp!";
}

fn on_ready(_id: int, _handle: void*) -> void {
    Window{id: _id, handle: _handle}.show();
}

fn run_app() -> int {
    let config = AppConfig{
        name: "kitchen-sink",
        applicationShouldTerminateAfterLastWindowClosed: true,
        webContentInspectable: Zapp::inspectable_auto(),
        maxWorkers: 0,
        qjsStackSize: 0,
    };
    let app = App::new(config);
    app.service.add("greet", greet);

    // The kitchen-sink main window IS the native-chrome shell: a leading
    // NSSplitViewItem sidebar (nav) + a trailing inspector. All panes load
    // the same bundle, branched on location.hash. "#sidebar-pane" /
    // "#inspector-pane" resolve against the app's base URL natively
    // (webview.m zapp_resolve_url), so a bare hash is correct here.
    let opts = WindowOptions::create("Kitchen Sink");
    opts.visible = false;
    opts.width = 1100;
    opts.height = 700;
    opts.sidebarUrl = "#sidebar-pane";
    opts.sidebarWidth = 240;
    opts.inspectorUrl = "#inspector-pane";
    opts.inspectorWidth = 300;
    opts.inspectorCollapsed = true;
    let win = app.window.create(&opts);
    win.on_ready(on_ready);

    return app.run();
}
```

- [ ] **Step 2: Minimal hash-branching `main.ts`**

Replace `kitchen-sink/src/main.ts` with this throwaway placeholder (Task 3 rewrites it):
```ts
import "./style.css";

const hash = location.hash;
const app = document.querySelector<HTMLDivElement>("#app")!;
const label =
  hash === "#sidebar-pane" ? "SIDEBAR PANE" :
  hash === "#inspector-pane" ? "INSPECTOR PANE" :
  "MAIN PANE";
app.innerHTML = `<div style="padding:var(--zapp-titlebar-height,52px) 16px 16px;font:13px system-ui">${label}</div>`;
document.body.style.background = (hash === "#sidebar-pane" || hash === "#inspector-pane") ? "transparent" : "";
```

- [ ] **Step 3: Delete the default-template counter**

Run: `rm kitchen-sink/src/counter.ts`

- [ ] **Step 4: Build**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run build 2>&1 | tail -5`
Expected last line: `[zapp] build complete: <path>`.

- [ ] **Step 5: GATE — human smoke (zc build)**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run dev`
Expected: the window opens showing **three regions** — a left native sidebar reading "SIDEBAR PANE", a center "MAIN PANE", and (since `inspectorCollapsed: true`) a collapsed trailing inspector that appears as "INSPECTOR PANE" when expanded (drag the right edge or wait for Task 3's toggle).
**If the sidebar/inspector panes do NOT appear** (the window opens as a single plain pane): this is feasibility Risk #1 — the initial `app.window.create` isn't allocating sidebar/inspector transport slots. **STOP and report to the controller** with the observation. Do not edit `native/**`. The controller decides between (a) a small framework fix or (b) the fallback (shell as the first JS-created window).

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add kitchen-sink/zapp/app.zc kitchen-sink/src/main.ts
git commit -m "$(printf 'feat(kitchen-sink): initial-window native-chrome shell + pane router stub\n\nThe main window is created with sidebar + inspector opts in app.zc; main.ts\nbranches on location.hash to label each pane. Risk-first slice: validates the\ninitial window mounts native sidebar/inspector on the zc build before the\nsections are built.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```
(Note: `counter.ts` was deleted but never committed in this repo state, so it needs no `git rm` — if `git status` shows it staged for deletion, include `kitchen-sink/src/counter.ts` in the `git add`.)

---

## Task 2: Section registry types + `findSection` (TDD)

**Goal:** The pure spine — the `Section` contract and a tested lookup helper, with no runtime import so the test is alias-free.

**Files:**
- Create: `kitchen-sink/src/sections/types.ts`
- Test: `kitchen-sink/src/sections/types.test.ts`

- [ ] **Step 1: Write the failing test**

Create `kitchen-sink/src/sections/types.test.ts`:
```ts
import { test, expect } from "bun:test";
import { findSection, type Section } from "./types";

const fixtures: Section[] = [
  { id: "alpha", label: "Alpha", render() {} },
  { id: "beta", label: "Beta", render() {} },
];

test("findSection returns the matching section", () => {
  expect(findSection(fixtures, "beta")?.label).toBe("Beta");
});

test("findSection returns undefined for an unknown id", () => {
  expect(findSection(fixtures, "missing")).toBeUndefined();
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun test src/sections/types.test.ts`
Expected: FAIL — cannot resolve `./types`.

- [ ] **Step 3: Write `types.ts`**

Create `kitchen-sink/src/sections/types.ts`:
```ts
/** One feature showcase. Lives in src/sections/<id>.ts; registered in
 *  registry.ts. The sidebar pane renders one nav row per Section, the main
 *  pane renders render(), the inspector pane renders inspector(). render and
 *  inspector run in DIFFERENT webview panes (same bundle) and may return a
 *  teardown fn — the panes call it before switching sections so event
 *  subscriptions don't leak. */
export interface Section {
  id: string;
  label: string;
  /** Optional sf: symbol id for the sidebar nav row (cosmetic). */
  icon?: string;
  /** Paint the main pane into `host`. Optional teardown returned. */
  render(host: HTMLElement): void | (() => void);
  /** Paint the inspector pane into `host`. Optional teardown returned. */
  inspector?(host: HTMLElement): void | (() => void);
}

export function findSection(list: Section[], id: string): Section | undefined {
  return list.find((s) => s.id === id);
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun test src/sections/types.test.ts`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add kitchen-sink/src/sections/types.ts kitchen-sink/src/sections/types.test.ts
git commit -m "$(printf 'feat(kitchen-sink): section registry types + findSection (TDD)\n\nSection contract (render/inspector with optional teardown) + a pure,\nalias-free findSection helper, unit-tested with bun:test.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 3: Shell panes + style + the first real section (Sidebar) — GATE

**Goal:** Wire the full shell — sidebar nav, main stage (+ toolbar attach), inspector — driven by the registry, with the Sidebar section as the first real entry so the nav→render→inspector loop is proven end-to-end.

**Files:**
- Create: `kitchen-sink/src/shell/ui.ts`, `kitchen-sink/src/shell/toolbar-def.ts`, `kitchen-sink/src/shell/router.ts`, `kitchen-sink/src/shell/sidebar-pane.ts`, `kitchen-sink/src/shell/main-pane.ts`, `kitchen-sink/src/shell/inspector-pane.ts`
- Create: `kitchen-sink/src/sections/sidebar.ts`, `kitchen-sink/src/sections/registry.ts`
- Modify: `kitchen-sink/src/main.ts`, `kitchen-sink/src/style.css`

- [ ] **Step 1: DOM helpers (`ui.ts`)**

Create `kitchen-sink/src/shell/ui.ts`:
```ts
/** Build a section "card": a titled block with a button row and a result area.
 *  Returns the card element; query buttons by their data-act value. */
export function card(opts: {
  title: string;
  intro?: string;
  buttons: { act: string; label: string }[];
}): HTMLElement {
  const el = document.createElement("section");
  el.className = "card";
  const btns = opts.buttons
    .map((b) => `<button data-act="${b.act}">${b.label}</button>`)
    .join("");
  el.innerHTML = `
    <h2>${opts.title}</h2>
    ${opts.intro ? `<p class="intro">${opts.intro}</p>` : ""}
    <div class="row">${btns}</div>
    <div class="result" data-result></div>`;
  return el;
}

/** Wire a click handler keyed by data-act. */
export function onAct(host: HTMLElement, act: string, fn: () => void) {
  host.querySelector<HTMLButtonElement>(`[data-act="${act}"]`)
    ?.addEventListener("click", fn);
}

/** Write to the card's result area. */
export function setResult(host: HTMLElement, msg: string) {
  const r = host.querySelector<HTMLDivElement>("[data-result]");
  if (r) r.textContent = msg;
}
```

- [ ] **Step 2: Shared toolbar definition (`toolbar-def.ts`)**

Create `kitchen-sink/src/shell/toolbar-def.ts`:
```ts
import { Events, type ToolbarItemDef } from "@zappdev/runtime";

// Filter state for the pull-down's moving checkmark (the Toolbar section
// drives this via updateItem). Module-level so main-pane (attach) and the
// Toolbar section (re-attach) share one source of truth.
let filter = "all";
export function getFilter() { return filter; }
export function setFilter(f: string) { filter = f; }

export function filterMenu(): any[] {
  return [
    { id: "kf-all",     label: "All",     checked: filter === "all" },
    { id: "kf-unread",  label: "Unread",  checked: filter === "unread" },
    { id: "kf-flagged", label: "Flagged", checked: filter === "flagged" },
  ];
}

/** The shell toolbar: toggleSidebar | tracking | Compose | flex | Filter |
 *  tracking(inspector) | toggleInspector. Compose/Filter are the items the
 *  Toolbar section mutates. */
export function shellToolbar(): ToolbarItemDef[] {
  return [
    { type: "toggleSidebar" },
    { type: "trackingSeparator" },
    { id: "compose", icon: "sf:square.and.pencil", label: "Compose",
      action: () => Events.emit("ks:toolbar", { id: "compose" }) },
    { type: "flexibleSpace" },
    { id: "filter", icon: "sf:line.3.horizontal.decrease", label: "Filter",
      indicator: false, menu: filterMenu() },
    { type: "trackingSeparator", pane: "inspector" },
    { type: "toggleInspector" },
  ];
}
```

- [ ] **Step 3: Sidebar pane (`sidebar-pane.ts`)**

Create `kitchen-sink/src/shell/sidebar-pane.ts`:
```ts
import { Events } from "@zappdev/runtime";
import { registry } from "../sections/registry";

export function renderSidebarPane(app: HTMLElement) {
  document.body.style.background = "transparent";
  app.innerHTML = `
    <div class="sidebar-pane">
      <div class="sidebar-title">KITCHEN SINK</div>
      <nav>${registry.map((s) =>
        `<button class="nav-item" data-id="${s.id}">${s.label}</button>`).join("")}</nav>
    </div>`;
  const items = app.querySelectorAll<HTMLButtonElement>(".nav-item");
  items.forEach((el) =>
    el.addEventListener("click", () => {
      items.forEach((i) => i.classList.toggle("active", i === el));
      Events.emit("ks:nav", { id: el.dataset.id! });
    }));
  // Auto-select the first section so the main/inspector panes aren't empty.
  items[0]?.click();
}
```

- [ ] **Step 4: Main pane (`main-pane.ts`)**

Create `kitchen-sink/src/shell/main-pane.ts`:
```ts
import { Window, Events, Services } from "@zappdev/runtime";
import { registry } from "../sections/registry";
import { findSection } from "../sections/types";
import { shellToolbar } from "./toolbar-def";

export async function renderMainPane(app: HTMLElement) {
  app.innerHTML = `
    <div class="main-pane">
      <div class="landing" data-landing>
        <h1>Kitchen Sink</h1>
        <p>Pick a feature in the sidebar. Each section has a trigger and a
           visible result; the inspector (right) shows live state.</p>
        <p class="muted" data-greet>greet: …</p>
      </div>
      <div class="stage" data-stage></div>
    </div>`;

  // Prove Services round-trips end-to-end inside the shell.
  try {
    const msg = await Services.invoke("greet", { name: "Kitchen Sink" });
    app.querySelector("[data-greet]")!.textContent = `greet → ${msg}`;
  } catch (e) {
    app.querySelector("[data-greet]")!.textContent = `greet error: ${e}`;
  }

  // Attach the shell toolbar (late-attach to a toolbar-less window works).
  try {
    Window.current().toolbar.setItems(shellToolbar());
  } catch (e) {
    console.warn("[kitchen-sink] toolbar attach failed:", e);
  }

  const stage = app.querySelector<HTMLElement>("[data-stage]")!;
  const landing = app.querySelector<HTMLElement>("[data-landing]")!;
  let teardown: void | (() => void);

  Events.on("ks:nav", ({ id }: any) => {
    if (typeof teardown === "function") teardown();
    const section = findSection(registry, id);
    if (!section) return;
    landing.style.display = "none";
    stage.innerHTML = "";
    teardown = section.render(stage);
  });
}
```

- [ ] **Step 5: Inspector pane (`inspector-pane.ts`)**

Create `kitchen-sink/src/shell/inspector-pane.ts`:
```ts
import { Events } from "@zappdev/runtime";
import { registry } from "../sections/registry";
import { findSection } from "../sections/types";

export function renderInspectorPane(app: HTMLElement) {
  document.body.style.background = "transparent";
  app.innerHTML = `
    <div class="inspector-pane">
      <div class="inspector-title">INSPECTOR</div>
      <div class="inspector-body" data-body>
        <p class="muted">Select a feature to see live state.</p>
      </div>
    </div>`;
  const body = app.querySelector<HTMLElement>("[data-body]")!;
  let teardown: void | (() => void);

  Events.on("ks:nav", ({ id }: any) => {
    if (typeof teardown === "function") teardown();
    const section = findSection(registry, id);
    body.innerHTML = "";
    if (section?.inspector) {
      teardown = section.inspector(body);
    } else {
      body.innerHTML = `<p class="muted">No inspector for this section.</p>`;
      teardown = undefined;
    }
  });
}
```

- [ ] **Step 6: Shell router (`router.ts`)**

Create `kitchen-sink/src/shell/router.ts`:
```ts
import { renderSidebarPane } from "./sidebar-pane";
import { renderMainPane } from "./main-pane";
import { renderInspectorPane } from "./inspector-pane";

export function routeShell(app: HTMLElement) {
  switch (location.hash) {
    case "#sidebar-pane":   renderSidebarPane(app); break;
    case "#inspector-pane": renderInspectorPane(app); break;
    // "#popover-pane" added in Task 6.
    default:                void renderMainPane(app); break;
  }
}
```

- [ ] **Step 7: The first real section (`sections/sidebar.ts`)**

Create `kitchen-sink/src/sections/sidebar.ts`:
```ts
import { Window, WindowEvent } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct, setResult } from "../shell/ui";

export const sidebarSection: Section = {
  id: "sidebar",
  label: "Sidebar",
  render(host) {
    const win = Window.current();
    host.appendChild(card({
      title: "Native Sidebar",
      intro: "A real NSSplitViewItem sidebar (this window's left nav). Toggling hides the nav; the toolbar's sidebar button brings it back.",
      buttons: [
        { act: "toggle", label: "Toggle" },
        { act: "w180", label: "Width 180" },
        { act: "w320", label: "Width 320" },
      ],
    }));
    onAct(host, "toggle", () => { win.sidebar?.toggle(); setResult(host, "toggled"); });
    onAct(host, "w180", () => { win.sidebar?.setWidth(180); setResult(host, "width → 180"); });
    onAct(host, "w320", () => { win.sidebar?.setWidth(320); setResult(host, "width → 320"); });
  },
  inspector(host) {
    const win = Window.current();
    host.innerHTML = `<div class="kv"><b>Sidebar</b><div data-state class="muted">observing…</div></div>`;
    const state = host.querySelector<HTMLElement>("[data-state]")!;
    const off = [
      win.on(WindowEvent.SIDEBAR_COLLAPSED, () => { state.textContent = "collapsed"; }),
      win.on(WindowEvent.SIDEBAR_EXPANDED, () => { state.textContent = "expanded"; }),
      win.on(WindowEvent.SIDEBAR_RESIZED, (d: any) => { state.textContent = `width ${d.width}`; }),
    ];
    return () => off.forEach((fn) => fn());
  },
};
```

- [ ] **Step 8: Registry (`sections/registry.ts`)**

Create `kitchen-sink/src/sections/registry.ts`:
```ts
import type { Section } from "./types";
import { sidebarSection } from "./sidebar";

// Sections appended in later tasks: inspector, toolbar, popover, multiwindow.
export const registry: Section[] = [
  sidebarSection,
];
```

- [ ] **Step 9: Entry (`main.ts`)**

Replace `kitchen-sink/src/main.ts` with:
```ts
import "./style.css";
import { routeShell } from "./shell/router";

routeShell(document.querySelector<HTMLDivElement>("#app")!);
```

- [ ] **Step 10: Shell styling (`style.css`)**

Replace `kitchen-sink/src/style.css` with:
```css
:root {
  --text: #6b6375; --text-h: #08060d; --bg: #fff; --border: #e5e4e7;
  --code-bg: #f4f3ec; --accent: #aa3bff; --accent-bg: rgba(170, 59, 255, 0.1);
  --accent-border: rgba(170, 59, 255, 0.5);
  font: 14px/1.45 system-ui, "Segoe UI", Roboto, sans-serif;
  color-scheme: light dark; color: var(--text); background: var(--bg);
  -webkit-font-smoothing: antialiased;
}
@media (prefers-color-scheme: dark) {
  :root {
    --text: #9ca3af; --text-h: #f3f4f6; --bg: #16171d; --border: #2e303a;
    --code-bg: #1f2028; --accent: #c084fc; --accent-bg: rgba(192, 132, 252, 0.15);
    --accent-border: rgba(192, 132, 252, 0.5);
  }
}
body { margin: 0; }
h1 { font-size: 28px; color: var(--text-h); margin: 0 0 8px; font-weight: 600; }
h2 { font-size: 16px; color: var(--text-h); margin: 0 0 8px; font-weight: 600; }
.muted { opacity: 0.6; font-size: 12px; }

/* Sidebar pane */
.sidebar-pane { padding: var(--zapp-titlebar-height, 52px) 8px 8px; }
.sidebar-title { opacity: 0.5; font-size: 11px; letter-spacing: 0.06em; padding: 0 8px 8px; }
.nav-item {
  display: block; width: 100%; text-align: left; border: 0; background: transparent;
  color: var(--text-h); padding: 7px 10px; border-radius: 6px; font: inherit; cursor: default;
}
.nav-item:hover { background: var(--accent-bg); }
.nav-item.active { background: var(--accent-bg); color: var(--accent); font-weight: 600; }

/* Main pane */
.main-pane { padding: var(--zapp-titlebar-height, 52px) 24px 24px; max-width: 720px; }
.landing { margin-bottom: 16px; }
.stage { display: flex; flex-direction: column; gap: 16px; }
.card { border: 1px solid var(--border); border-radius: 10px; padding: 16px; }
.card .intro { margin: 0 0 12px; opacity: 0.7; font-size: 12px; }
.card .row { display: flex; flex-wrap: wrap; gap: 8px; }
.card button {
  font: inherit; color: var(--accent); background: var(--accent-bg);
  border: 1px solid transparent; border-radius: 6px; padding: 6px 12px; cursor: default;
}
.card button:hover { border-color: var(--accent-border); }
.card .result { font-family: ui-monospace, Consolas, monospace; font-size: 12px;
  opacity: 0.8; margin-top: 10px; white-space: pre-wrap; min-height: 16px; }

/* Inspector pane */
.inspector-pane { padding: var(--zapp-titlebar-height, 52px) 12px 12px; }
.inspector-title { opacity: 0.5; font-size: 11px; letter-spacing: 0.06em; margin-bottom: 10px; }
.kv b { color: var(--text-h); display: block; margin-bottom: 4px; }
```

- [ ] **Step 11: Build**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run build 2>&1 | tail -5`
Expected last line: `[zapp] build complete: <path>`.

- [ ] **Step 12: GATE — human smoke (zc build)**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run dev`
Expected: window opens with a left **native sidebar** listing "Sidebar"; the main pane shows the landing ("greet → Hello from Zapp!") then the Sidebar section's card; a **native toolbar** with a sidebar-toggle button + Compose + Filter + inspector-toggle. Click **Toggle** / **Width 180/320** → the native sidebar responds; expand the inspector (toolbar inspector button) → it reads the live width/collapsed state.

- [ ] **Step 13: Commit**

```bash
cd /Users/zach/code/zapp
git add kitchen-sink/src/shell/ kitchen-sink/src/sections/sidebar.ts kitchen-sink/src/sections/registry.ts kitchen-sink/src/main.ts kitchen-sink/src/style.css
git commit -m "$(printf 'feat(kitchen-sink): registry-driven shell (panes + toolbar) + Sidebar section\n\nsidebar/main/inspector panes generated from the section registry, selection\nover the Events bus (ks:nav); main pane attaches the shell toolbar + proves\nServices via greet. Sidebar section is the first real entry (toggle/setWidth +\nlive inspector state).\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 4: Inspector section

**Files:**
- Create: `kitchen-sink/src/sections/inspector.ts`
- Modify: `kitchen-sink/src/sections/registry.ts`

- [ ] **Step 1: Write `sections/inspector.ts`**

Create `kitchen-sink/src/sections/inspector.ts`:
```ts
import { Window, WindowEvent } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct, setResult } from "../shell/ui";

export const inspectorSection: Section = {
  id: "inspector",
  label: "Inspector",
  render(host) {
    const win = Window.current();
    host.appendChild(card({
      title: "Native Inspector",
      intro: "A trailing NSSplitViewItem inspector. This section drives the very pane it reports into (right).",
      buttons: [
        { act: "toggle", label: "Toggle" },
        { act: "w360", label: "Width 360" },
      ],
    }));
    onAct(host, "toggle", () => { win.inspector?.toggle(); setResult(host, "toggled"); });
    onAct(host, "w360", () => { win.inspector?.setWidth(360); setResult(host, "width → 360"); });
  },
  inspector(host) {
    const win = Window.current();
    host.innerHTML = `<div class="kv"><b>Inspector</b><div data-state class="muted">observing…</div></div>`;
    const state = host.querySelector<HTMLElement>("[data-state]")!;
    const off = [
      win.on(WindowEvent.INSPECTOR_COLLAPSED, () => { state.textContent = "collapsed"; }),
      win.on(WindowEvent.INSPECTOR_EXPANDED, () => { state.textContent = "expanded"; }),
      win.on(WindowEvent.INSPECTOR_RESIZED, (d: any) => { state.textContent = `width ${d.width}`; }),
    ];
    return () => off.forEach((fn) => fn());
  },
};
```

- [ ] **Step 2: Register it**

In `kitchen-sink/src/sections/registry.ts`, add the import and array entry:
```ts
import type { Section } from "./types";
import { sidebarSection } from "./sidebar";
import { inspectorSection } from "./inspector";

export const registry: Section[] = [
  sidebarSection,
  inspectorSection,
];
```

- [ ] **Step 3: Build**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run build 2>&1 | tail -5`
Expected last line: `[zapp] build complete: <path>`.

- [ ] **Step 4: Commit**

```bash
cd /Users/zach/code/zapp
git add kitchen-sink/src/sections/inspector.ts kitchen-sink/src/sections/registry.ts
git commit -m "$(printf 'feat(kitchen-sink): Inspector section (toggle/setWidth + live state)\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 5: Toolbar section

**Files:**
- Create: `kitchen-sink/src/sections/toolbar.ts`
- Modify: `kitchen-sink/src/sections/registry.ts`

- [ ] **Step 1: Write `sections/toolbar.ts`**

Create `kitchen-sink/src/sections/toolbar.ts`:
```ts
import { Window, WindowEvent } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct, setResult } from "../shell/ui";
import { shellToolbar, filterMenu, getFilter, setFilter } from "../shell/toolbar-def";

let composeEnabled = true;

export const toolbarSection: Section = {
  id: "toolbar",
  label: "Toolbar",
  render(host) {
    const win = Window.current();
    host.appendChild(card({
      title: "Dynamic Toolbar",
      intro: "Mutates the native toolbar above. The Filter button's checkmark moves via updateItem; remove/attach changes the titlebar height.",
      buttons: [
        { act: "toggle-compose", label: "Toggle Compose enabled" },
        { act: "cycle-filter", label: "Cycle filter (moving checkmark)" },
        { act: "remove", label: "Remove toolbar" },
        { act: "attach", label: "Attach toolbar" },
      ],
    }));
    onAct(host, "toggle-compose", () => {
      composeEnabled = !composeEnabled;
      win.toolbar.updateItem("compose", { enabled: composeEnabled });
      setResult(host, `compose enabled: ${composeEnabled}`);
    });
    onAct(host, "cycle-filter", () => {
      const order = ["all", "unread", "flagged"];
      setFilter(order[(order.indexOf(getFilter()) + 1) % order.length]);
      win.toolbar.updateItem("filter", { menu: filterMenu() });
      setResult(host, `filter → ${getFilter()} (reopen the Filter menu to see the checkmark move)`);
    });
    onAct(host, "remove", () => {
      win.toolbar.remove();
      setResult(host, "toolbar removed — watch the titlebar shrink");
    });
    onAct(host, "attach", () => {
      composeEnabled = true;
      win.toolbar.setItems(shellToolbar());
      setResult(host, "toolbar attached — titlebar grows back");
    });
  },
  inspector(host) {
    const win = Window.current();
    host.innerHTML = `<div class="kv"><b>Toolbar</b><div data-state class="muted">click a toolbar item…</div></div>`;
    const state = host.querySelector<HTMLElement>("[data-state]")!;
    const off = win.on(WindowEvent.TOOLBAR_CLICKED, (p: any) => { state.textContent = `clicked: ${p.id}`; });
    return () => off();
  },
};
```

- [ ] **Step 2: Register it**

In `kitchen-sink/src/sections/registry.ts`:
```ts
import type { Section } from "./types";
import { sidebarSection } from "./sidebar";
import { inspectorSection } from "./inspector";
import { toolbarSection } from "./toolbar";

export const registry: Section[] = [
  sidebarSection,
  inspectorSection,
  toolbarSection,
];
```

- [ ] **Step 3: Build**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run build 2>&1 | tail -5`
Expected last line: `[zapp] build complete: <path>`.

- [ ] **Step 4: Commit**

```bash
cd /Users/zach/code/zapp
git add kitchen-sink/src/sections/toolbar.ts kitchen-sink/src/sections/registry.ts
git commit -m "$(printf 'feat(kitchen-sink): Toolbar section (enable/disable, moving checkmark, remove/attach)\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 6: Popover section + popover pane

**Files:**
- Create: `kitchen-sink/src/shell/popover-pane.ts`, `kitchen-sink/src/sections/popover.ts`
- Modify: `kitchen-sink/src/shell/router.ts`, `kitchen-sink/src/sections/registry.ts`

- [ ] **Step 1: Popover pane content (`popover-pane.ts`)**

Create `kitchen-sink/src/shell/popover-pane.ts`:
```ts
import { Events } from "@zappdev/runtime";

export function renderPopoverPane(app: HTMLElement) {
  document.body.style.background = "transparent";
  let n = 0;
  app.innerHTML = `
    <div style="padding:14px;font:13px system-ui">
      <div style="font-weight:600;margin-bottom:8px">Web content in an NSPopover</div>
      <button data-count>Count: 0</button>
      <button data-emit>Emit → main pane</button>
    </div>`;
  app.querySelector("[data-count]")!.addEventListener("click", (e) => {
    (e.currentTarget as HTMLElement).textContent = `Count: ${++n}`; // survives hide/show
  });
  app.querySelector("[data-emit]")!.addEventListener("click", () => {
    Events.emit("ks:popover-emit", { from: "popover" });
  });
}
```

- [ ] **Step 2: Add the `#popover-pane` route**

In `kitchen-sink/src/shell/router.ts`, add the import and case:
```ts
import { renderSidebarPane } from "./sidebar-pane";
import { renderMainPane } from "./main-pane";
import { renderInspectorPane } from "./inspector-pane";
import { renderPopoverPane } from "./popover-pane";

export function routeShell(app: HTMLElement) {
  switch (location.hash) {
    case "#sidebar-pane":   renderSidebarPane(app); break;
    case "#inspector-pane": renderInspectorPane(app); break;
    case "#popover-pane":   renderPopoverPane(app); break;
    default:                void renderMainPane(app); break;
  }
}
```

- [ ] **Step 3: Write `sections/popover.ts`**

Create `kitchen-sink/src/sections/popover.ts`:
```ts
import { Window, WindowEvent, Events, type PopoverHandle } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct, setResult } from "../shell/ui";

export const popoverSection: Section = {
  id: "popover",
  label: "Popover",
  render(host) {
    const win = Window.current();
    host.appendChild(card({
      title: "Popover (web content in NSPopover)",
      intro: "Created lazily, reused after — the counter inside survives hide/show. Anchor to a button or to the Compose toolbar item.",
      buttons: [
        { act: "from-button", label: "Popover from this button" },
        { act: "from-toolbar", label: "Popover from Compose item" },
      ],
    }));
    let pop: PopoverHandle | undefined;
    const ensure = async () => (pop ??= await win.createPopover({ url: "#popover-pane", width: 280, height: 180 }));
    onAct(host, "from-button", async (...args) => {
      const btn = host.querySelector<HTMLElement>('[data-act="from-button"]')!;
      (await ensure()).show(btn);
      setResult(host, "shown (anchored to button)");
    });
    onAct(host, "from-toolbar", async () => {
      (await ensure()).show({ toolbarItem: "compose" });
      setResult(host, "shown (anchored to Compose toolbar item)");
    });
    const off = [
      win.on(WindowEvent.POPOVER_CLOSED, (p: any) => setResult(host, `closed: ${p.popoverId}`)),
      Events.on("ks:popover-emit", () => setResult(host, "popover emitted an event → main pane received it")),
    ];
    return () => off.forEach((fn) => fn());
  },
};
```

Note: `onAct`'s handler takes no args; the `(...args)` above is harmless but tidy it to `async ()` — corrected form:
```ts
    onAct(host, "from-button", async () => {
      const btn = host.querySelector<HTMLElement>('[data-act="from-button"]')!;
      (await ensure()).show(btn);
      setResult(host, "shown (anchored to button)");
    });
```

- [ ] **Step 4: Register it**

In `kitchen-sink/src/sections/registry.ts`:
```ts
import type { Section } from "./types";
import { sidebarSection } from "./sidebar";
import { inspectorSection } from "./inspector";
import { toolbarSection } from "./toolbar";
import { popoverSection } from "./popover";

export const registry: Section[] = [
  sidebarSection,
  inspectorSection,
  toolbarSection,
  popoverSection,
];
```

- [ ] **Step 5: Build**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run build 2>&1 | tail -5`
Expected last line: `[zapp] build complete: <path>`.

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add kitchen-sink/src/shell/popover-pane.ts kitchen-sink/src/shell/router.ts kitchen-sink/src/sections/popover.ts kitchen-sink/src/sections/registry.ts
git commit -m "$(printf 'feat(kitchen-sink): Popover section + popover pane\n\nNSPopover web content anchored to a button or the Compose toolbar item;\npersistent counter survives hide/show; POPOVER_CLOSED + cross-pane emit.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 7: Multi-window section (Nim-aware)

**Files:**
- Create: `kitchen-sink/src/sections/multiwindow.ts`
- Modify: `kitchen-sink/src/sections/registry.ts`

- [ ] **Step 1: Write `sections/multiwindow.ts`**

Create `kitchen-sink/src/sections/multiwindow.ts`:
```ts
import { Window } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct, setResult } from "../shell/ui";

// Each trigger try/catches: on the Nim build (no WindowManager yet) Window.create
// rejects — surface that as a clear note instead of a silent failure.
async function open(host: HTMLElement, label: string, fn: () => Promise<{ id: string }>) {
  try {
    const w = await fn();
    setResult(host, `${label} → ${w.id}`);
  } catch (e) {
    setResult(host, `${label} failed — likely needs WindowManager (zc build for now): ${e}`);
  }
}

export const multiwindowSection: Section = {
  id: "multiwindow",
  label: "Multi-window",
  render(host) {
    const win = Window.current();
    host.appendChild(card({
      title: "Windows & Sheets",
      intro: "Open additional windows. On the Nim build these are gated on the WindowManager port — the result line says so.",
      buttons: [
        { act: "plain", label: "New window" },
        { act: "small", label: "New window (small)" },
        { act: "vibrant", label: "Vibrancy (sidebar)" },
        { act: "sheet-page", label: "Sheet (page)" },
        { act: "sheet-form", label: "Sheet (form)" },
        { act: "sheet-bottom", label: "Bottom sheet" },
      ],
    }));
    onAct(host, "plain", () => open(host, "window", () =>
      Window.create({ title: "Kitchen Sink — Window", width: 800, height: 600, backgroundColor: "#1e1e1e" })));
    onAct(host, "small", () => open(host, "small window", () =>
      Window.create({ title: "Small", width: 400, height: 300 })));
    onAct(host, "vibrant", () => open(host, "vibrant window", () =>
      Window.create({ title: "Vibrancy", width: 480, height: 360, vibrancy: "sidebar", titleBarStyle: "hiddenInset" })));
    onAct(host, "sheet-page", () => open(host, "page sheet", () =>
      Window.create({ title: "Settings", width: 480, height: 600, asSheetOf: win, presentation: "page", grabber: true })));
    onAct(host, "sheet-form", () => open(host, "form sheet", () =>
      Window.create({ title: "Quick Add", width: 400, height: 300, asSheetOf: win, presentation: "form", grabber: true })));
    onAct(host, "sheet-bottom", () => open(host, "bottom sheet", () =>
      Window.create({ title: "Drawer", asSheetOf: win, presentation: "bottomSheet", detents: ["medium", "large"], grabber: true })));
  },
};
```

- [ ] **Step 2: Register it**

In `kitchen-sink/src/sections/registry.ts`:
```ts
import type { Section } from "./types";
import { sidebarSection } from "./sidebar";
import { inspectorSection } from "./inspector";
import { toolbarSection } from "./toolbar";
import { popoverSection } from "./popover";
import { multiwindowSection } from "./multiwindow";

export const registry: Section[] = [
  sidebarSection,
  inspectorSection,
  toolbarSection,
  popoverSection,
  multiwindowSection,
];
```

- [ ] **Step 3: Build**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run build 2>&1 | tail -5`
Expected last line: `[zapp] build complete: <path>`.

- [ ] **Step 4: Commit**

```bash
cd /Users/zach/code/zapp
git add kitchen-sink/src/sections/multiwindow.ts kitchen-sink/src/sections/registry.ts
git commit -m "$(printf 'feat(kitchen-sink): Multi-window section (windows + sheets, Nim-aware)\n\nWindow.create variants (plain/small/vibrancy/page-form-bottom sheets); each\ncatches failure and surfaces a "needs WindowManager (zc build for now)" note.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 8: SMOKE.md + final full smoke — GATE + done

**Files:**
- Create: `kitchen-sink/SMOKE.md`

- [ ] **Step 1: Write `kitchen-sink/SMOKE.md`**

Create `kitchen-sink/SMOKE.md`:
```markdown
# Kitchen Sink — Smoke Checklist

The structured manual smoke surface (replaces ad-hoc clicking around hello-world).
Run `bun run dev` (zc — full features) from `kitchen-sink/`. The `nim ⏳` column
tracks `ZAPP_NATIVE_LANG=nim bun run dev`: native chrome lights up once the
WindowManager port lands; non-chrome works today.

## Shell
| Check | Expected | zc | nim |
|---|---|---|---|
| Launch | Window opens: native sidebar (left nav), main pane, collapsed inspector, native toolbar | ✓ | ⏳ |
| Landing | Main pane shows "greet → Hello from Zapp!" (Services round-trip) | ✓ | ✓ |
| Nav | Clicking a sidebar row swaps the main pane + inspector | ✓ | ⏳ |

## Sidebar section
| Check | Expected | zc | nim |
|---|---|---|---|
| Toggle | native sidebar hides/shows; toolbar sidebar button also toggles | ✓ | ⏳ |
| Width 180 / 320 | sidebar resizes; inspector pane shows `width 180`/`320` | ✓ | ⏳ |

## Inspector section
| Check | Expected | zc | nim |
|---|---|---|---|
| Toggle | trailing inspector hides/shows | ✓ | ⏳ |
| Width 360 | inspector resizes; its own pane reads `width 360` | ✓ | ⏳ |

## Toolbar section
| Check | Expected | zc | nim |
|---|---|---|---|
| Toggle Compose enabled | Compose item greys out / re-enables | ✓ | ⏳ |
| Cycle filter | reopen Filter menu → checkmark moved | ✓ | ⏳ |
| Remove / Attach | titlebar shrinks then grows back | ✓ | ⏳ |

## Popover section
| Check | Expected | zc | nim |
|---|---|---|---|
| From button / toolbar | NSPopover with web content appears at the anchor | ✓ | ⏳ |
| Counter | increments and survives hide/show | ✓ | ⏳ |
| Emit → main pane | result line confirms cross-pane event | ✓ | ⏳ |

## Multi-window section
| Check | Expected | zc | nim |
|---|---|---|---|
| New window / small / vibrancy | a window opens; result logs its id | ✓ | ⏳ (shows "needs WindowManager") |
| Sheets (page/form/bottom) | a sheet attaches to the shell window | ✓ | ⏳ |
```

- [ ] **Step 2: Verify `.gitignore` keeps artifacts out (no change expected)**

Run: `cd /Users/zach/code/zapp && git status --porcelain kitchen-sink/ | grep -E "bin/|dist/|\.zapp/|node_modules/|src/zapp/" || echo "clean — artifacts ignored"`
Expected: `clean — artifacts ignored` (the existing `kitchen-sink/.gitignore` already excludes `bin/ dist/ .zapp/ node_modules src/zapp/`). `build/` is intentionally tracked (committable app assets, matching hello-world). If any artifact path appears, do NOT commit it — report.

- [ ] **Step 3: Final full build**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run build 2>&1 | tail -5`
Expected last line: `[zapp] build complete: <path>`.

- [ ] **Step 4: GATE — full visual smoke (zc build)**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run dev`
Walk the whole `SMOKE.md` zc column: shell launches as the native-chrome shell, all five sections behave as described, the inspector tracks live state, the popover shows web content, new windows/sheets open. Confirm with the user.

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add kitchen-sink/SMOKE.md
git commit -m "$(printf 'docs(kitchen-sink): SMOKE.md cycle-1 checklist (shell + 5 chrome sections)\n\nStructured manual smoke surface (steps -> expected -> zc/nim columns) that\nreplaces ad-hoc hello-world clicking and grows with each cycle.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Self-Review

**1. Spec coverage:**
- Shell architecture (multi-pane, hash-branched, Events bus) → Tasks 1, 3. ✓
- Section registry spine → Task 2 (+ grows 3–7). ✓
- Five cycle-1 sections (sidebar/inspector/toolbar/popover/multi-window) → Tasks 3, 4, 5, 6, 7. ✓
- Popover pane (4th hash branch) → Task 6. ✓
- `app.zc` initial-window chrome → Task 1. ✓
- Toolbar attached from JS → Task 3 (main-pane). ✓
- `SMOKE.md` → Task 8. ✓
- Build-agnostic / smoke matrix / Risk #1 gate → Task 1 GATE + plan preamble. ✓
- Commit source only, explicit paths, `.gitignore` verify → every task + Task 8 Step 2. ✓
- `zapp.config.ts` stays minimal (no workers) → unchanged, no task touches it. ✓ (correct — deferred to cycle 2)

**2. Placeholder scan:** No TBD/TODO. Every code step is complete. The Task 6 `onAct(...(...args)...)` slip is explicitly corrected inline in the same step. The Task 1 GATE "STOP and report" is a real decision branch, not a hand-wave.

**3. Type consistency:** `Section` (id/label/icon?/render/inspector?) defined in Task 2 and used identically in Tasks 3–7. `findSection(list, id)` signature matches its callers in main-pane/inspector-pane. `registry: Section[]` import path (`../sections/registry`) consistent. Runtime imports (`Window`, `Events`, `Services`, `WindowEvent`, `PopoverHandle`, `ToolbarItemDef`) match `runtime/index.ts` exports. `win.sidebar?.toggle()/setWidth()`, `win.inspector?.toggle()/setWidth()`, `win.toolbar.setItems()/updateItem()/remove()`, `win.createPopover().show()` match the runtime signatures (window.ts). `WindowEvent.SIDEBAR_*/INSPECTOR_*/TOOLBAR_CLICKED/POPOVER_CLOSED` exist (events.ts). `shellToolbar`/`filterMenu`/`getFilter`/`setFilter` shared between toolbar-def, main-pane, and the Toolbar section. ✓
