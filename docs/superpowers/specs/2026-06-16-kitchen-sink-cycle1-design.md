# Kitchen-Sink App — Cycle 1 (Native-Chrome Shell) Design

**Date:** 2026-06-16
**Branch:** `feat/nim-native` (the app source is build-agnostic; it lives here per user direction and becomes the yardstick for the WindowManager Nim cycle)
**Status:** Approved design → ready for implementation plan

## Purpose

Build out the so-far-unused `kitchen-sink/` scaffold into the project's **showcase + structured-smoke vehicle**, starting with the native-chrome family (sidebar / inspector / toolbar / popover / multi-window). It will eventually replace `hello-world` as the canonical app the dev cycles smoke against; `hello-world` stays in parallel for now (and remains the small-binary benchmark vehicle — kitchen-sink is intentionally bigger and must not replace it in size benchmarks). See [[project_kitchen_sink_app]].

This is **cycle 1 of a multi-cycle effort**. Later cycles (each its own spec) add: Workers + Sync · Notifications/Shortcuts/Clipboard/Screens/Power · Dialogs + FS · Tray + Menus · Protocols/Deep-links/Single-instance/Auto-launch · then the docs/README swap that formally retires hello-world.

## Build reality (the smoke matrix)

The app source (TS + `app.zc`) is **build-agnostic** — the same kitchen-sink runs on either native layer; the build is chosen at launch:

| Launch | Native layer | What smokes |
|---|---|---|
| `bun run dev` (default) | **zc** | The *full* app — native sidebar + inspector + toolbar + popover + new windows. **Primary dev/smoke driver.** Works today. |
| `ZAPP_NATIVE_LANG=nim bun run dev` | **Nim** | Non-chrome sections smoke now; the native-chrome shell lights up once the **WindowManager port** lands on Nim. Kitchen-sink is the exact yardstick for that cycle ("when the shell appears under `nim`, WindowManager is done"). |

Why: native sidebar/inspector mount extra webview panes whose transport slots are allocated by `WindowManager` (`WindowOptions.sidebarNumericId`/`inspectorNumericId`, window.zc:114-130) — and WindowManager is not yet ported to Nim. Cycle 1's chrome therefore smokes on the **zc build**; that is expected and fine.

## Architecture

### The shell — one multi-pane native-chrome window

The kitchen-sink main window is a **single multi-pane native-chrome window**, created with `sidebar` + `inspector` + `toolbar`. All panes load the **same Vite bundle**, branching on `location.hash` (the proven hello-world pattern):

- **Sidebar pane** (`#sidebar-pane`) — the app nav. One row per registered feature `Section`; clicking emits `ks:nav { id }` over the `Events` bus.
- **Main pane** (`#main-pane`, also the default/no-hash) — the stage. Listens for `ks:nav`, renders the active section's `render()` into `#app`, and attaches the shell toolbar.
- **Inspector pane** (`#inspector-pane`) — live detail. Renders the active section's `inspector()`.
- **Popover pane** (`#popover-pane`) — web content shown inside an `NSPopover` (used by the Popover section).
- **Toolbar** — `toggleSidebar` · `trackingSeparator` · section-contributed buttons · `toggleInspector`.

Cross-pane selection travels over the `Events` bus (`ks:nav`), exactly as hello-world's `sb:nav` does — the panes are separate JS contexts (separate webviews), so the shared `registry` array (imported in each) keeps them from drifting while `Events` carries the live selection.

### The section registry — the extensibility spine

One module, `src/sections/registry.ts`, exports an ordered `Section[]`:

```ts
export interface Section {
  id: string;            // "sidebar", "inspector", "toolbar", "popover", "multiwindow"
  label: string;         // sidebar nav label
  icon?: string;         // sf: symbol for the nav row (optional; cosmetic)
  render(host: HTMLElement): void;        // paint the main pane into `host`
  inspector?(host: HTMLElement): void;    // optional: paint the inspector pane
}
```

Adding a feature in a later cycle = drop one `src/sections/<name>.ts` and append it to the registry array — nothing else changes. The sidebar pane, main pane, and inspector pane are all generated from this single list. Each section owns its own DOM and a small inline "result" area (the structured-showcase contract: **trigger → visible result**).

Toolbar contributions are intentionally **not** part of the `Section` interface in cycle 1: the shell toolbar is fixed (`toggleSidebar`/`compose`/`filter`/`toggleInspector`) and the Toolbar *section* mutates it via the runtime `win.toolbar` API as its demo. A per-section `toolbar()` contribution hook is a candidate for a later cycle if a section needs it (YAGNI now).

## Components

### `src/main.ts` — entry
Reads `location.hash`, delegates to the shell router. No feature logic.

### `src/shell/router.ts`
Pure dispatch: `#sidebar-pane → renderSidebarPane()`, `#inspector-pane → renderInspectorPane()`, `#popover-pane → renderPopoverPane()`, else `renderMainPane()`.

### `src/shell/main-pane.ts`
- Renders a landing intro into `#app` when no section is selected yet (brief "Kitchen Sink — pick a feature in the sidebar" + a `greet` round-trip line to prove Services works end-to-end in the shell).
- Attaches the shell toolbar via `Window.current().toolbar.setItems(shellToolbar())` (late-attach to the initially toolbar-less window — hello-world proves this works; avoids hand-authoring `toolbarJson` in `app.zc`).
- `Events.on("ks:nav", ({id}) => { activeSection = findSection(id); activeSection.render(#app); })`. The inspector pane subscribes to the same `ks:nav` broadcast independently (it is an `Events` broadcast heard by every pane) — no re-broadcast needed.

### `src/shell/sidebar-pane.ts`
Renders nav rows from `registry` (label + optional icon). Click → `Events.emit("ks:nav", { id })`. Marks the active row.

### `src/shell/inspector-pane.ts`
Subscribes to `ks:nav`; on change, clears and calls the active section's `inspector?.(host)`. Sections without an inspector render a neutral placeholder.

### `src/sections/registry.ts`
`export const registry: Section[] = [sidebarSection, inspectorSection, toolbarSection, popoverSection, multiwindowSection];`
Plus a `findSection(id)` helper.

### The five sections (`src/sections/*.ts`)

All import the runtime from `@zappdev/runtime`. The first four act **self-referentially on the shell window's own chrome** — the main pane's `Window.current()` resolves to the shell window, and any pane receives `.sidebar` / `.inspector` / `.toolbar` / `.createPopover` handles.

1. **`sidebar.ts`** — `render`: buttons for `win.sidebar.toggle()`, `collapse`/`expand` (toggle), `setWidth(180)` / `setWidth(320)`. `inspector`: live width + collapsed state, updated from `WindowEvent.SIDEBAR_RESIZED/COLLAPSED/EXPANDED`. (Toggling hides the nav; the toolbar's `toggleSidebar` and the section's own button bring it back — authentic Mail-like behavior.)
2. **`inspector.ts`** — `render`: `win.inspector.toggle()`, `setWidth(360)`. `inspector`: reflects `WindowEvent.INSPECTOR_RESIZED/COLLAPSED/EXPANDED` — the section drives the very pane it reports into.
3. **`toolbar.ts`** — `render`: enable/disable the `compose` item (`win.toolbar.updateItem("compose", { enabled })`), `remove`, re-attach (`win.toolbar.setItems(shellToolbar())`), and a filter pull-down whose checkmark moves via `updateItem` (the moving-checkmark gate). Result line echoes the last op and `WindowEvent.TOOLBAR_CLICKED`.
4. **`popover.ts`** — `render`: a button that does `(await win.createPopover({ url: "#popover-pane", width: 280, height: 180 })).show(button)`, and a second that anchors to a toolbar item (`.show({ toolbarItem: "compose" })`). Popover content (rendered by `renderPopoverPane`) is a counter that survives hide/show (proves persistent web content). `WindowEvent.POPOVER_CLOSED` logged to the result area.
5. **`multiwindow.ts`** — `render`: `Window.create` variants — plain (800×600, `backgroundColor`), small (400×300), vibrancy (`vibrancy:"sidebar"`, `titleBarStyle:"hiddenInset"`), and sheets (`asSheetOf: win` with `presentation: page/form/bottomSheet`, `grabber: true`, `detents`). Each logs the child id. **Nim-aware:** each trigger wraps the call in try/catch and, on failure, writes a clear "needs WindowManager (zc build for now)" message to the result area rather than failing silently — this is the section that visibly tracks the WindowManager Nim cycle.

### `src/style.css`
Three-pane shell aesthetic + section "cards" (heading, button row, monospace result area). Pane chrome respects `--zapp-titlebar-height`/`--zapp-toolbar-height` CSS vars (as hello-world does) so content clears the native titlebar/toolbar. Sidebar/inspector panes draw on transparent background (the native material shows through).

### `zapp/app.zc`
The initial window is created **with sidebar + inspector opts**:
```
let opts = WindowOptions::create("Kitchen Sink");
opts.visible = false;
opts.width = 1100; opts.height = 700;
opts.sidebarUrl = "#sidebar-pane";   opts.sidebarWidth = 240;
opts.inspectorUrl = "#inspector-pane"; opts.inspectorWidth = 300; opts.inspectorCollapsed = true;
let win = app.window.create(&opts);
win.on_ready(on_ready);
```
`greet` stays registered (used by the main-pane landing line). The toolbar is attached from JS (main pane), not here.

### `zapp.config.ts`
Stays minimal this cycle (name/identifier/version already present). No headless workers yet (cycle 2).

## Smoke surface

`kitchen-sink/SMOKE.md` — the structured manual checklist run each cycle. One row per feature: **steps → expected visible result → build (zc ✓ / nim ⏳)**. Cycle 1 populates the five chrome sections; later cycles append. This replaces ad-hoc "click around hello-world" with a written, repeatable surface and is the doc that eventually retires hello-world.

## Risks / open items

1. **Initial-window chrome slot allocation (the one feasibility gate).** Native sidebar/inspector need `WindowManager`-allocated transport slots; this has only ever been exercised on JS-created windows (`__window:create`), never the *initial* `app.window.create`. The plan's **first task** validates the initial window mounts sidebar+inspector on the zc build. If `app.window.create` doesn't allocate the slots for the initial window, the fix is small (in `window.zc`/`app.zc`, same `WindowManager`); **fallback** if it proves involved: the shell opens as the first JS-created window (still full-featured on zc) and we file the initial-window-chrome gap separately. This risk is zc-side and does not affect the broader Nim migration.
2. **Toolbar late-attach timing.** Attaching the toolbar from the main pane means a brief frame where the window has no toolbar. Acceptable for a showcase. If a flash is objectionable, a later refinement can author `toolbarJson` in `app.zc`.
3. **Nim build chrome.** Expected non-functional until WindowManager ports — surfaced honestly in the Multi-window section and `SMOKE.md` (the `nim ⏳` column), not a bug.

## Scope / non-goals (cycle 1)

- IN: the shell (sidebar/inspector/toolbar panes + registry), the five chrome sections, the popover pane, `app.zc` initial-window chrome, `SMOKE.md`, committing kitchen-sink source.
- OUT (later cycles): workers/sync, notifications/shortcuts/clipboard/screens/power, dialogs/fs, tray/menus, protocols/deep-links/single-instance/auto-launch, per-section toolbar-contribution hook, automated headless e2e probes, the docs/README swap that retires hello-world.

## Commit / staging discipline

Commit kitchen-sink **source** only — explicit paths (`kitchen-sink/src/**`, `kitchen-sink/zapp/app.zc`, `kitchen-sink/zapp.config.ts`, `kitchen-sink/index.html`, `kitchen-sink/package.json`, `kitchen-sink/vite.config.ts`, `kitchen-sink/tsconfig.json`, `kitchen-sink/.gitignore`, `kitchen-sink/SMOKE.md`, the spec/plan docs). The plan verifies `kitchen-sink/.gitignore` excludes `bin/ dist/ .zapp/ node_modules/ build/`. **Never** `git add -A`; never stage other WIP dirs (`vendor/`, etc.). This is the intentional reversal of the prior "never stage kitchen-sink" rule, which existed only to keep the untracked scaffold out of migration commits — building+committing it is now the goal.
