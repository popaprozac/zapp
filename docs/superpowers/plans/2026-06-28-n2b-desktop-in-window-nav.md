# N2b — Desktop In-Window Navigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make the N2a router visible on desktop — convert the kitchen-sink's flat section nav into a real per-window history stack driven by `Window.current().router`, bind the N1 toolbar back/forward buttons to `router.pop()`/`router.forward()` with enabled-state from `canGoBack`/`canGoForward`, fix the N2a M-c seed-vs-event race, and wire the `window.create`-on-iPhone → `router.push` fallback.

**Architecture:** One window hosts N separate pane-webviews sharing one native-authoritative route stack (N2a). Navigation is always *initiate → native → `ROUTE_CHANGED` broadcast → render* (the event is the only cross-pane channel). T1 hardens the runtime router handle (no native change); T2 rewires the kitchen-sink panes + toolbar to drive it.

**Tech Stack:** TypeScript runtime + kitchen-sink (Bun), `bun:test`.

## Global Constraints

- Branch `feat/ios-native-nav` — commit directly. NO git worktree, NO `git commit --amend`, NO merge.
- Commit trailer EXACTLY: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- Per-file `git add` ONLY — never `-A`/`.`. Pre-existing unrelated WIP stays unstaged.
- Bun, never Node.
- **NO native/Nim change** — the wire (N2a) already exists; N2b is the TS/app consumer + docs.
- macOS is the testable reference; iOS must keep COMPILING (iOS native routing is N3 — N2b adds none).
- Spec: `docs/superpowers/specs/2026-06-28-n2b-desktop-in-window-nav-design.md`.

Per-task gates: `bun run check`; `bun test cli/src`; `bun run test:native`; macOS build (`cd kitchen-sink && bun run build` → `[zapp] build complete:`); iOS compile (`cd kitchen-sink && bun run build --platform ios` → `[zapp] build complete:`). T1 also `bun test runtime/router.test.ts`; T2 also `bun test kitchen-sink/src/shell/route-map.test.ts`.

---

## Task 1: Framework — router handle hardening + iPhone create fallback (TDD)

**Files:**
- Modify: `runtime/window.ts` — the `RouterHandle` interface (~1125–1150), `createRouterHandle` (1351–1429), and the `Window.create` iOS branch (1633–1640).
- Test: `runtime/router.test.ts` (extend).

**Interfaces:**
- Consumes: `getBridge()`, `eventName(WindowEvent.ROUTE_CHANGED)`, `windowAction`, `Platform.isIOS`, `Window.current()` (all already in `runtime/window.ts`).
- Produces (consumed by Task 2): `RouterHandle.current(): Promise<{ url: string; params: Record<string, unknown> | null; canGoBack: boolean; canGoForward: boolean }>` — async read of the authoritative current route (updates + returns the cache). The cache record gains a `version` field. `Window.create({url,…})` on iOS (non-sheet) now performs `router.push` instead of a pure no-op.

> **Test isolation note:** `routerState`/`routerWired` are module-level singletons that persist across tests (only the mock bridge resets in `beforeEach`). Every test below MUST use a unique `windowId` (e.g. `win-mc`, `win-once`, `win-cur`, `win-iose`) so a prior test's wired listener/cache doesn't leak in.

### Step 1 — Write the failing tests

Append to `runtime/router.test.ts` (it already imports `createWindowHandle, Window` from `./window` and `WindowEvent, eventName` from `./events`, and installs a mock bridge with `posts`/`invokes`/`fire`/`invokeResult` on `globalThis[Symbol.for("zapp.bridge")]`):

```ts
// ── M-c: async seed must not clobber a ROUTE_CHANGED that arrived first ────────
describe("router seed vs event race (M-c)", () => {
  const EVENT = eventName(WindowEvent.ROUTE_CHANGED);

  test("a ROUTE_CHANGED before the seed resolves wins over the stale seed", async () => {
    // The seed invoke resolves to a STALE snapshot (root):
    mock.invokeResult = { url: "/", params: null, canGoBack: false, canGoForward: false };
    const win = createWindowHandle("win-mc");
    // A push lands (event) before the async seed promise resolves:
    mock.fire(EVENT, { windowId: "win-mc", url: "/fresh", params: null, canGoBack: true, canGoForward: false });
    // Flush the seed's .then microtask(s):
    await Promise.resolve(); await Promise.resolve();
    expect(win.router.url).toBe("/fresh");        // event value retained
    expect(win.router.canGoBack).toBe(true);      // NOT clobbered back to false
  });
});

// ── M-a: seed invoke fires once per window ────────────────────────────────────
test("__router:state seed invoke fires once per window (M-a)", () => {
  createWindowHandle("win-once");
  createWindowHandle("win-once");
  createWindowHandle("win-once");
  const seeds = mock.invokes.filter((i) => i.method === "__router:state" && i.args.windowId === "win-once");
  expect(seeds.length).toBe(1);
});

// ── router.current(): async authoritative read ────────────────────────────────
test("router.current() resolves the native snapshot and updates the cache", async () => {
  mock.invokeResult = { url: "/deep", params: { a: 1 }, canGoBack: true, canGoForward: false };
  const win = createWindowHandle("win-cur");
  const snap = await win.router.current();
  expect(snap.url).toBe("/deep");
  expect(snap.canGoBack).toBe(true);
  expect(win.router.url).toBe("/deep"); // cache updated too
});

// ── iOS: Window.create non-sheet falls back to router.push ─────────────────────
describe("Window.create iOS single-window fallback", () => {
  const BC = Symbol.for("zapp.bootstrapConfig");
  const WID = Symbol.for("zapp.windowId");
  afterEach(() => {
    delete (globalThis as any)[BC];
    delete (globalThis as any)[WID];
  });

  test("create({url,title}) on iOS posts router:push and returns the current window", async () => {
    // Mirror platform.test.ts's bootstrapConfig shape for os=ios:
    (globalThis as any)[BC] = { permissions: { platform: "ios" } };
    (globalThis as any)[WID] = "win-iose";
    const w = await Window.create({ url: "/detail", title: "Detail" });
    const pushMsg = mock.posts.map((p) => JSON.parse(p)).find((m) => m.m === "router:push");
    expect(pushMsg).toEqual({ t: 4, m: "router:push", a: { windowId: "win-iose", url: "/detail", title: "Detail" } });
    expect(w.id).toBe("win-iose");
    expect(mock.invokes.some((i) => i.method === "__window:create")).toBe(false);
  });

  test("create({title}) with no url on iOS does NOT push", async () => {
    (globalThis as any)[BC] = { permissions: { platform: "ios" } };
    (globalThis as any)[WID] = "win-iose2";
    const before = mock.posts.length;
    await Window.create({ title: "X" });
    const pushed = mock.posts.slice(before).map((p) => JSON.parse(p)).some((m) => m.m === "router:push");
    expect(pushed).toBe(false);
  });
});
```

Add `afterEach` to the existing `bun:test` import line if absent: `import { describe, expect, test, beforeEach, afterEach } from "bun:test";`.

### Step 2 — Run the tests, verify they FAIL

Run: `bun test runtime/router.test.ts`
Expected: FAIL — `router.current` is not a function; M-a sees 3 seed invokes not 1; M-c retains `/` not `/fresh`.

### Step 3 — Add `current()` to the `RouterHandle` interface

In `runtime/window.ts`, read the `RouterHandle` interface (~1125–1150). After the `on(...)` method signature and before/after the getters, add:

```ts
  /** Resolve the authoritative current route from native (async). Updates the
   *  cache and returns the snapshot. Use for first render / reload-restore,
   *  where the synchronously-cached getters may not be seeded yet. */
  current(): Promise<{ url: string; params: Record<string, unknown> | null; canGoBack: boolean; canGoForward: boolean }>;
```

### Step 4 — Rewrite `createRouterHandle` (M-c version-stamp + fold M-a + `current()`)

Replace lines 1351–1392 (the `routerState` map decl through the `routerWired.add(windowId)` block) with:

```ts
const routerState = new Map<string, { url: string; params: Record<string, unknown> | null; canGoBack: boolean; canGoForward: boolean; version: number }>();

/** Windows whose ROUTE_CHANGED bridge listener is already registered. */
const routerWired = new Set<string>();

/** Create a RouterHandle that caches route state from ROUTE_CHANGED events. */
function createRouterHandle(windowId: string): RouterHandle {
  // Seed with defaults on first creation; leave alone if already seeded.
  if (!routerState.has(windowId)) {
    routerState.set(windowId, { url: "", params: null, canGoBack: false, canGoForward: false, version: 0 });
  }

  // Wire the live listener + best-effort seed ONCE per window (M-a). The seed is
  // version-guarded so a push that lands before it resolves is never clobbered
  // by the stale snapshot (M-c).
  if (!routerWired.has(windowId)) {
    const bridge = getBridge();
    bridge.on(eventName(WindowEvent.ROUTE_CHANGED), (payload: any) => {
      if (payload?.windowId === windowId) {
        const rec = routerState.get(windowId);
        if (rec) {
          rec.url          = payload.url;
          rec.params       = payload.params ?? null;
          rec.canGoBack    = payload.canGoBack;
          rec.canGoForward = payload.canGoForward;
          rec.version++;
        }
      }
    });
    const seedVersion = routerState.get(windowId)!.version;
    bridge.invoke("__router:state", { windowId }).then((r: any) => {
      if (r && typeof r === "object") {
        const rec = routerState.get(windowId);
        // Only apply the seed if no ROUTE_CHANGED arrived meanwhile (M-c).
        if (rec && rec.version === seedVersion) {
          if (typeof r.url === "string")              rec.url          = r.url;
          if (r.params !== undefined)                 rec.params       = r.params ?? null;
          if (typeof r.canGoBack === "boolean")       rec.canGoBack    = r.canGoBack;
          if (typeof r.canGoForward === "boolean")    rec.canGoForward = r.canGoForward;
        }
      }
    }).catch(() => { /* best-effort — ignore failures (e.g. route not yet seeded) */ });
    routerWired.add(windowId);
  }
```

(The `return { … }` block that follows is unchanged except for the `current()` addition in Step 5.)

### Step 5 — Add `current()` to the returned handle

In the `return { … }` object of `createRouterHandle` (after the `params` getter, ~line 1427), add:

```ts
    async current() {
      const r: any = await getBridge().invoke("__router:state", { windowId });
      const rec = routerState.get(windowId);
      if (rec && r && typeof r === "object") {
        if (typeof r.url === "string")           rec.url          = r.url;
        if (r.params !== undefined)              rec.params       = r.params ?? null;
        if (typeof r.canGoBack === "boolean")    rec.canGoBack    = r.canGoBack;
        if (typeof r.canGoForward === "boolean") rec.canGoForward = r.canGoForward;
        rec.version++; // authoritative read counts as a write so a racing seed won't clobber it
      }
      return {
        url:          rec?.url ?? "",
        params:       rec?.params ?? null,
        canGoBack:    rec?.canGoBack ?? false,
        canGoForward: rec?.canGoForward ?? false,
      };
    },
```

### Step 6 — Wire the iOS `Window.create` fallback

Replace the iOS branch (1633–1640) with:

```ts
    if (Platform.isIOS && opts?.asSheetOf === undefined) {
      const current = Window.current();
      if (opts?.url) {
        // iOS is single-window: a non-sheet create becomes an in-window route
        // push. The logical stack + ROUTE_CHANGED + content-swap all work on the
        // single webview; native UINavigationController routing is a later cycle.
        console.warn(
          "[zapp] iOS is single-window — Window.create() without `asSheetOf` became an " +
          "in-window route push (router.push). Use a sheet (`asSheetOf`) for a modal " +
          "surface; iPad multi-window is planned.",
        );
        current.router.push({
          url: opts.url,
          ...(opts.title !== undefined ? { title: opts.title } : {}),
          ...(opts.presentation !== undefined ? { presentation: opts.presentation } : {}),
        });
      } else {
        console.warn(
          "[zapp] iOS is single-window — Window.create() without `asSheetOf` is a no-op " +
          "(returns the current window). Use a sheet (`asSheetOf`) or a sidebar/inspector " +
          "pane for secondary surfaces; iPad multi-window is planned.",
        );
      }
      return current;
    }
```

### Step 7 — Run the tests, verify they PASS

Run: `bun test runtime/router.test.ts`
Expected: PASS (all new + all pre-existing N2a cases).

### Step 8 — Full gates

Run: `bun run check`; `bun test cli/src`; `bun run test:native`; `cd kitchen-sink && bun run build` (expect `[zapp] build complete:`); `cd kitchen-sink && bun run build --platform ios` (expect `[zapp] build complete:`).

### Step 9 — Commit

```bash
git add runtime/window.ts runtime/router.test.ts
git commit  # message below, with the required trailer
```
Message: `feat(router): version-stamp cache (M-c) + once-per-window seed (M-a) + router.current() + iOS create→push fallback`

---

## Task 2: Kitchen-sink conversion + docs + macOS human smoke

**Files:**
- Create: `kitchen-sink/src/shell/route-map.ts`
- Create (test): `kitchen-sink/src/shell/route-map.test.ts`
- Modify: `kitchen-sink/src/shell/toolbar-def.ts`
- Modify: `kitchen-sink/src/shell/sidebar-pane.ts`
- Modify: `kitchen-sink/src/shell/main-pane.ts`
- Modify: `docs/api-reference.md` (Router section, ~1607)

**Interfaces:**
- Consumes (from Task 1): `Window.current().router` with `push`/`pop`/`forward` + `current()` + `url`/`canGoBack`/`canGoForward` getters + `on(handler)`; `Window.current().toolbar.updateItem(id, { enabled })`; `WindowEvent.ROUTE_CHANGED` (exported from `@zappdev/runtime`).
- Produces: `routeForSection(id: string): string`, `sectionForRoute(url: string): string`.

### Step 1 — Write the failing route-map test

Create `kitchen-sink/src/shell/route-map.test.ts`:

```ts
import { describe, expect, test } from "bun:test";
import { routeForSection, sectionForRoute } from "./route-map";

describe("route-map", () => {
  test("home maps to '/' both ways", () => {
    expect(routeForSection("home")).toBe("/");
    expect(sectionForRoute("/")).toBe("home");
    expect(sectionForRoute("")).toBe("home");
  });
  test("a section maps to '/<id>' both ways", () => {
    expect(routeForSection("toolbar")).toBe("/toolbar");
    expect(sectionForRoute("/toolbar")).toBe("toolbar");
  });
  test("round-trips section ids", () => {
    for (const id of ["home", "sidebar", "toolbar", "workers", "tray"]) {
      expect(sectionForRoute(routeForSection(id))).toBe(id);
    }
  });
});
```

### Step 2 — Run it, verify FAIL

Run: `bun test kitchen-sink/src/shell/route-map.test.ts`
Expected: FAIL — cannot find module `./route-map`.

### Step 3 — Create `route-map.ts`

```ts
/** Pure URL ⇄ section-id mapping for the kitchen-sink router. Home is the
 *  N2a-seeded root "/"; every other registry section is "/<id>". Shared by the
 *  sidebar (push) and main pane (render) so both agree on the scheme. */
export function routeForSection(id: string): string {
  return id === "home" ? "/" : "/" + id;
}

export function sectionForRoute(url: string): string {
  return url === "" || url === "/" ? "home" : url.replace(/^\//, "");
}
```

### Step 4 — Run it, verify PASS

Run: `bun test kitchen-sink/src/shell/route-map.test.ts`
Expected: PASS.

### Step 5 — Toolbar: back/fwd → top-level router-wired items

In `kitchen-sink/src/shell/toolbar-def.ts`: change the import line to include `Window`:

```ts
import {
  Events,
  Window,
  type ActionContext,
  type MenuItemDef,
  type ToolbarItemDef,
} from "@zappdev/runtime";
```

Then in `shellToolbar()`, **delete** the entire center `nav` group block (the `{ type: "group", id: "nav", placement: "center", … items: [back, fwd] }` object). **Insert** two top-level leading items immediately after the `{ type: "trackingSeparator" }` (the first one) and before the `compose` item:

```ts
    {
      id: "back",
      icon: "sf:chevron.left",
      label: "Back",
      enabled: false, // wired live to router.canGoBack by main-pane
      action: () => Window.current().router.pop(),
    },
    {
      id: "fwd",
      icon: "sf:chevron.right",
      label: "Forward",
      enabled: false, // wired live to router.canGoForward by main-pane
      action: () => Window.current().router.forward(),
    },
```

Leave compose/inbox/view/fmt/filter/status/trackingSeparator/toggleInspector unchanged. (`back`/`fwd` are now top-level so `toolbar.updateItem("back"/"fwd", {enabled})` can address them.)

### Step 6 — Sidebar: push on click + highlight follows the route

Replace `kitchen-sink/src/shell/sidebar-pane.ts` entirely with:

```ts
import { Window, Platform, WindowEvent } from "@zappdev/runtime";
import { registry } from "../sections/registry";
import { routeForSection, sectionForRoute } from "./route-map";

export function renderSidebarPane(app: HTMLElement) {
  // Chrome panes must be fully transparent (html + body) so the native sidebar
  // glass — and any content mirror behind it (backgroundExtension) — shows
  // through. Body alone isn't enough: the opaque :root/html background blocks it.
  document.documentElement.style.background = "transparent";
  document.body.style.background = "transparent";
  const dragStrip = Platform.isIOS
    ? ""
    : `<div class="drag-strip" data-zapp-drag-region></div>`;
  app.innerHTML = `
    ${dragStrip}
    <div class="sidebar-pane">
      <div class="sidebar-title">KITCHEN SINK</div>
      <nav>${registry
        .map(
          (s) =>
            `<button class="nav-item" data-id="${s.id}">${s.label}</button>`,
        )
        .join("")}</nav>
    </div>`;
  const items = app.querySelectorAll<HTMLButtonElement>(".nav-item");

  // Click → router.push the section's route. The native stack fans out
  // ROUTE_CHANGED to every pane; we don't toggle .active here (see below).
  items.forEach((el) =>
    el.addEventListener("click", () => {
      Window.current().router.push(routeForSection(el.dataset.id!));
      // iPhone master-detail: reveal the content column full-screen.
      if (Platform.isIOS) Window.current().sidebar?.showContent();
    }),
  );

  // Highlight follows the current route, so back/forward move it too (#666).
  const applyActive = (url: string) => {
    const sectionId = sectionForRoute(url);
    items.forEach((i) => i.classList.toggle("active", i.dataset.id === sectionId));
  };
  Window.current().router.on((e) => applyActive(e.url));
  applyActive(Window.current().router.url); // initial (cache → "" → home)
}
```

### Step 7 — Main pane: render on ROUTE_CHANGED + toolbar enabled-sync + first render via current()

Replace `kitchen-sink/src/shell/main-pane.ts` entirely with:

```ts
import { Window, Platform, WindowEvent } from "@zappdev/runtime";
import { registry } from "../sections/registry";
import { findSection } from "../sections/types";
import { shellToolbar } from "./toolbar-def";
import { sectionForRoute } from "./route-map";

export function renderMainPane(app: HTMLElement) {
  const dragStrip = Platform.isIOS
    ? ""
    : `<div class="drag-strip" data-zapp-drag-region>
      <span class="drag-strip-label">⠿ Kitchen Sink — drag to move</span>
    </div>`;
  app.innerHTML = `
    ${dragStrip}
    <div class="main-pane"><div class="stage" data-stage></div></div>`;

  // Attach the shell toolbar (late-attach to a toolbar-less window works).
  // On iOS this renders as a native UINavigationItem nav bar (N1).
  try {
    Window.current().toolbar.setItems(shellToolbar());
  } catch (e) {
    console.warn("[kitchen-sink] toolbar attach failed:", e);
  }

  const stage = app.querySelector<HTMLElement>("[data-stage]")!;
  let teardown: void | (() => void);
  let shownId = "";

  const show = (id: string) => {
    if (id === shownId) return;          // already rendering this section
    if (typeof teardown === "function") teardown();
    teardown = undefined;
    const section = findSection(registry, id);
    if (!section) return;
    shownId = id;
    stage.innerHTML = "";
    teardown = section.render(stage);
  };

  const win = Window.current();
  const syncToolbar = (canGoBack: boolean, canGoForward: boolean) => {
    try {
      win.toolbar.updateItem("back", { enabled: canGoBack });
      win.toolbar.updateItem("fwd",  { enabled: canGoForward });
    } catch { /* toolbar not ready — ignore */ }
  };

  // Render on every route change (sidebar click, toolbar back/forward, etc.).
  win.router.on((e) => {
    show(sectionForRoute(e.url));
    syncToolbar(e.canGoBack, e.canGoForward);
  });

  // First render: show home immediately (cache may be unseeded), then correct to
  // the authoritative route (restores a deep route after reload).
  show(sectionForRoute(win.router.url));
  syncToolbar(win.router.canGoBack, win.router.canGoForward);
  win.router.current().then((snap) => {
    show(sectionForRoute(snap.url));
    syncToolbar(snap.canGoBack, snap.canGoForward);
  }).catch(() => { /* best-effort restore */ });
}
```

### Step 8 — Verify no stale `ks:nav` references remain

Run: `grep -rn "ks:nav" kitchen-sink/src`
Expected: no matches (both the emit in sidebar-pane and the listener in main-pane are gone). If any remain, remove them.

### Step 9 — Docs

In `docs/api-reference.md`, find the `### Router` section (~1607). After the existing router API content (and before the next `###`), add a subsection:

```markdown
#### Desktop in-window navigation

On desktop the router drives **in-window** navigation: the route stack is logical
and content is swapped within the existing webview (there are no per-route
windows — that is iOS's model). Wire it like this:

- **Navigate:** call `Window.current().router.push("/section")` from anywhere
  (a sidebar button, a menu, a worker via `Window.get(id)`).
- **Render:** subscribe once and swap content on the event — never render
  directly from the click. In a multi-pane window the click happens in one
  webview (e.g. the sidebar) and the content lives in another, so the
  `ROUTE_CHANGED` broadcast is the only cross-pane channel:

  ```ts
  Window.current().router.on((e) => renderRoute(e.url));
  // First render / reload-restore — read the authoritative route async:
  Window.current().router.current().then((s) => renderRoute(s.url));
  ```

- **Back/forward toolbar buttons:** give them ids, then sync their enabled-state
  from the same event:

  ```ts
  // toolbar items:  { id: "back", action: () => win.router.pop() }, { id: "fwd", action: () => win.router.forward() }
  win.router.on((e) => {
    win.toolbar.updateItem("back", { enabled: e.canGoBack });
    win.toolbar.updateItem("fwd",  { enabled: e.canGoForward });
  });
  ```

**iOS / single-window:** `Window.create(opts)` without `asSheetOf` is a no-op that
returns the current window — **except** when `opts.url` is set, in which case it
becomes an in-window `router.push({ url, title, presentation })` (iOS is
single-window; use a sheet via `asSheetOf` for a modal surface). Native
UINavigationController routing on iPhone is a later cycle.
```

Match the surrounding heading depth/style (the Router section uses `###`, so this subsection uses `####`).

### Step 10 — Full gates

Run: `bun run check`; `bun test cli/src`; `bun test kitchen-sink/src/shell/route-map.test.ts`; `bun run test:native`; `cd kitchen-sink && bun run build` (expect `[zapp] build complete:`); `cd kitchen-sink && bun run build --platform ios` (expect `[zapp] build complete:`).

### Step 11 — Commit

```bash
git add kitchen-sink/src/shell/route-map.ts kitchen-sink/src/shell/route-map.test.ts kitchen-sink/src/shell/toolbar-def.ts kitchen-sink/src/shell/sidebar-pane.ts kitchen-sink/src/shell/main-pane.ts docs/api-reference.md
git commit  # message below, with the required trailer
```
Message: `feat(kitchen-sink): router-driven section nav + toolbar back/forward (N2b)`

### Step 12 — macOS HUMAN SMOKE GATE

STOP for the controller/user. Run the kitchen-sink on macOS (`cd kitchen-sink && bun run dev`). Verify:
1. **Navigate** — click sidebar sections (Home → Sidebar → Toolbar → Workers): content swaps each time; the sidebar `.active` highlight moves to the clicked section.
2. **History** — the toolbar **Back** button enables after the first navigation; **Forward** is disabled until you go back.
3. **Back/forward traverse** — Back walks the visited sections in reverse; Forward re-walks them; the sidebar highlight follows both.
4. **Disable at the ends** — Back is disabled at Home (root); Forward is disabled at the newest entry.
5. **Reload restores route** — navigate to a deep section, reload the window (dev context-menu Reload): it lands back on that section, not Home.
6. macOS build + iOS compile both green.

---

## Self-Review

**Spec coverage:**
- §1 routing model → T2 (route-map, sidebar push + highlight, main-pane render + first-render-from-route, back/fwd top-level + router-wired). ✓
- §2 M-c fix + fold M-a → T1 (version-stamp + once-per-window seed). ✓
- §3 iPhone create fallback → T1 (iOS branch url→push) + tests. ✓
- §4 no native change, 2 tasks, gates → both tasks. ✓
- Reload-restore (spec §1 "first render reads router.url") → needed an async mechanism; added `router.current()` in T1 + used in main-pane T2. **Noted addition** beyond the spec's literal text, serving the spec's reload-restore smoke item.

**Placeholder scan:** none — every code step has full content; the only "read X" instruction (RouterHandle interface location for Step 3) is a concrete lookup with the exact signature given.

**Type/name consistency:** `routeForSection`/`sectionForRoute` identical across route-map.ts, sidebar-pane, main-pane, tests. `router.current()` signature identical in the interface (Step 3), the impl (Step 5), and the consumer (T2 main-pane). Item ids `back`/`fwd` identical in toolbar-def (Step 5) and the enabled-sync (T2 Step 7) and docs. `enabled` is an existing `ToolbarItemDef` field (used today). `WindowEvent.ROUTE_CHANGED` exported from `@zappdev/runtime` (confirmed in `runtime/index.ts`).
