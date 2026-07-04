import { describe, expect, test } from "bun:test";
import { Material, BackgroundExtension, applyToolbarConventions, normalizeToolbar, mergePaneToolbars } from "./window";
import type { WindowHandle } from "./window";
import { WindowEvent, eventName } from "./events";
import type { InspectorResizedPayload } from "./events";

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

test("sidebar window event wire names", () => {
  expect(eventName(WindowEvent.SIDEBAR_COLLAPSED)).toBe("window:sidebar-collapsed");
  expect(eventName(WindowEvent.SIDEBAR_EXPANDED)).toBe("window:sidebar-expanded");
  expect(eventName(WindowEvent.SIDEBAR_RESIZED)).toBe("window:sidebar-resized");
});

// INSPECTOR_RESIZED: wire name + typed on() overload (compile-level check).
expect(eventName(WindowEvent.INSPECTOR_RESIZED)).toBe("window:inspector-resized");
const _inspectorResizedTyped = (win: WindowHandle) =>
  win.on(WindowEvent.INSPECTOR_RESIZED, (p: InspectorResizedPayload) => void p.width);
void _inspectorResizedTyped;

describe("BackgroundExtension", () => {
  test("values are the wire strings", () => {
    expect(BackgroundExtension.None).toBe("none");
    expect(BackgroundExtension.Extend).toBe("extend");
    expect(BackgroundExtension.Mirror).toBe("mirror");
  });
  test("covers all three members", () => {
    expect(Object.values(BackgroundExtension).sort()).toEqual(["extend", "mirror", "none"]);
  });
  test("type is assignable from wire string", () => {
    const v: BackgroundExtension = "mirror";
    expect(v).toBe("mirror");
  });
});

describe("applyToolbarConventions", () => {
  const ts = (pane: string) => ({ type: "trackingSeparator", pane, placement: "leading" });
  const tgl = { type: "toggleSidebar", placement: "leading" };
  const insp = { type: "toggleInspector", placement: "trailing" };
  const btn = (id: string, placement = "leading") => ({ type: "button", id, placement });

  test("T1: anchors sidebar prefix with injected flex", () => {
    const out = applyToolbarConventions([btn("a"), tgl, ts("sidebar"), btn("b", "trailing")]);
    expect(out.slice(0, 3).map((i) => i.type)).toEqual(["flexibleSpace", "toggleSidebar", "trackingSeparator"]);
    expect(out[3]).toMatchObject({ id: "a" });
  });

  test("T1: toggleSidebar declared trailing is still anchored leading", () => {
    const out = applyToolbarConventions([btn("a"), { type: "toggleSidebar", placement: "trailing" }, ts("sidebar")]);
    expect(out[1]).toMatchObject({ type: "toggleSidebar", placement: "leading" });
  });

  test("T1: inspector suffix anchored trailing-most", () => {
    const out = applyToolbarConventions([insp, ts("inspector"), btn("z", "trailing")]);
    const types = out.map((i) => i.type);
    expect(types.slice(-2)).toEqual(["trackingSeparator", "toggleInspector"]);
    expect((out.at(-2) as any).pane).toBe("inspector");
  });

  test("T1: no flex without the separator; toggle anchored leading-first", () => {
    const out = applyToolbarConventions([btn("a"), tgl]);
    expect(out[0]).toMatchObject({ type: "toggleSidebar" });
    expect(out.some((i) => i.type === "flexibleSpace")).toBe(false);
  });

  test("T1: app-declared adjacent flex collapses into the injected one", () => {
    const out = applyToolbarConventions([{ type: "flexibleSpace", placement: "leading" }, tgl, ts("sidebar"), btn("a")]);
    expect(out.filter((i) => i.type === "flexibleSpace").length).toBe(1);
  });

  test("T1: duplicate system items collapse to one", () => {
    const out = applyToolbarConventions([tgl, btn("a"), { ...tgl }]);
    expect(out.filter((i) => i.type === "toggleSidebar").length).toBe(1);
  });

  test("T1: app items keep relative order and input is not mutated", () => {
    const input = [btn("a"), tgl, btn("b"), ts("sidebar"), btn("c", "trailing")];
    const snapshot = JSON.parse(JSON.stringify(input));
    const out = applyToolbarConventions(input);
    expect(out.filter((i: any) => i.type === "button").map((i: any) => i.id)).toEqual(["a", "b", "c"]);
    expect(input).toEqual(snapshot);
  });

  test("T1: normalizeToolbar output is conventionalized end-to-end", () => {
    const { json } = normalizeToolbar(
      { items: [ { id: "x", label: "X" } as any, { type: "toggleSidebar" } as any, { type: "trackingSeparator" } as any ] },
      true, false,
    );
    const wire = JSON.parse(json);
    expect(wire.items.slice(0, 3).map((i: any) => i.type)).toEqual(["flexibleSpace", "toggleSidebar", "trackingSeparator"]);
  });

  test("T3: warns when an icon-only segment omits label", () => {
    const warnings: string[] = [];
    const orig = console.warn;
    console.warn = (msg: string) => { warnings.push(String(msg)); };
    try {
      normalizeToolbar({ items: [ { type: "segmented", id: "seg", segments: [{ icon: "sf:star" }] } as any ] }, false, false);
    } finally { console.warn = orig; }
    expect(warnings.some((w) => w.includes("icon-only segment"))).toBe(true);
  });

  test("#744: segmented top-level label passes through to the wire item", () => {
    const { json } = normalizeToolbar(
      { items: [ { type: "segmented", id: "fmt", label: "Format", icon: "sf:textformat", segments: [{ id: "bold", icon: "sf:bold" }] } as any ] },
      false, false,
    );
    const wire = JSON.parse(json);
    expect(wire.items[0]).toMatchObject({ type: "segmented", id: "fmt", label: "Format", icon: "sf:textformat" });
  });

  test("#744: segmented item without a top-level label omits it from the wire", () => {
    const { json } = normalizeToolbar(
      { items: [ { type: "segmented", id: "fmt", segments: [{ id: "bold", icon: "sf:bold", label: "Bold" }] } as any ] },
      false, false,
    );
    const wire = JSON.parse(json);
    expect(wire.items[0]).not.toHaveProperty("label");
    expect(wire.items[0]).not.toHaveProperty("icon");
  });
});

// #782: pane-tagged toolbar items. Every item carries an optional
// `pane: "sidebar" | "inspector"`; applyToolbarConventions buckets tagged
// items into their pane region (before the sidebar tracking separator /
// after the inspector tracking separator) while untagged items stay in the
// content region exactly as before. The tracking separators have NO wire id —
// they're located by type+pane, and are synthesized when pane-tagged items
// need a region delimiter but none was declared.
describe("pane bucketing (#782)", () => {
  test("pane-tagged items order into their pane region; untagged stay in content", () => {
    const { json } = normalizeToolbar(
      { items: [
        { id: "s1", label: "New", pane: "sidebar" },
        { id: "c1", label: "Share" },
        { id: "i1", label: "Info", pane: "inspector" },
      ] },
      /*hasSidebar*/ true, /*hasInspector*/ true, /*windowId*/ "win-0",
    );
    const items = JSON.parse(json).items as Array<Record<string, any>>;
    const sidebarSep   = items.findIndex((i) => i.type === "trackingSeparator" && i.pane === "sidebar");
    const inspectorSep = items.findIndex((i) => i.type === "trackingSeparator" && i.pane === "inspector");
    const idx = (id: string) => items.findIndex((i) => i.id === id);
    expect(sidebarSep).toBeGreaterThanOrEqual(0);
    expect(inspectorSep).toBeGreaterThanOrEqual(0);
    expect(idx("s1")).toBeLessThan(sidebarSep);      // sidebar item BEFORE the sidebar separator
    expect(idx("c1")).toBeGreaterThan(sidebarSep);   // content BETWEEN the two separators
    expect(idx("c1")).toBeLessThan(inspectorSep);
    expect(idx("i1")).toBeGreaterThan(inspectorSep); // inspector item AFTER the inspector separator
  });

  // No-regression (ambiguity #3): an all-untagged item set keeps today's exact
  // ordering/behavior — content region between the two declared separators,
  // convention flex injected, no synthesized separators.
  test("untagged-only item set is ordered exactly as before pane tags existed", () => {
    const input = [
      { type: "button", id: "a", placement: "leading" },
      { type: "toggleSidebar", placement: "leading" },
      { type: "trackingSeparator", pane: "sidebar", placement: "leading" },
      { type: "button", id: "b", placement: "leading" },
      { type: "toggleInspector", placement: "trailing" },
      { type: "trackingSeparator", pane: "inspector", placement: "trailing" },
      { type: "button", id: "c", placement: "leading" },
    ];
    const out = applyToolbarConventions(input as any);
    // Exactly today's order: [flex, toggleSidebar, sep(sidebar), a, b, c, sep(inspector), toggleInspector].
    expect(out.map((i) => (i.id as string) ?? (i.type as string))).toEqual([
      "flexibleSpace", "toggleSidebar", "trackingSeparator",
      "a", "b", "c",
      "trackingSeparator", "toggleInspector",
    ]);
    // No separator was synthesized — the two present ones are the declared ones.
    expect(out.filter((i) => i.type === "trackingSeparator").length).toBe(2);
  });

  // Desugar (Step 4): a pane-scoped `sidebar.toolbar` folds its items into the
  // window toolbar def tagged pane:"sidebar" (inspector symmetric); the window's
  // own items stay untagged; the pane TITLE is not merged into any item.
  test("mergePaneToolbars tags pane items and leaves window items untagged", () => {
    const merged = mergePaneToolbars(
      { items: [{ id: "w1", label: "Win" }] },
      { items: [{ id: "s1", label: "New" }, { id: "s2", label: "Filter" }] },
      { items: [{ id: "i1", label: "Info" }] },
    );
    const by = (id: string) => merged!.items.find((i) => (i as any).id === id) as any;
    expect(by("w1").pane).toBeUndefined();
    expect(by("s1").pane).toBe("sidebar");
    expect(by("s2").pane).toBe("sidebar");
    expect(by("i1").pane).toBe("inspector");
    // No item was invented from a title (titles travel separately).
    expect(merged!.items.length).toBe(4);
  });

  test("mergePaneToolbars returns undefined when nothing brings a toolbar", () => {
    expect(mergePaneToolbars(undefined, undefined, undefined)).toBeUndefined();
  });

  // End-to-end: the desugared def, run through normalizeToolbar, buckets the
  // sidebar item ahead of the sidebar separator (title stays out of the wire).
  test("desugared sidebar toolbar buckets into the sidebar region end-to-end", () => {
    const merged = mergePaneToolbars(
      undefined,
      { items: [{ id: "s1", label: "New" }] },
      undefined,
    );
    const { json } = normalizeToolbar(merged!, /*hasSidebar*/ true, /*hasInspector*/ false);
    const items = JSON.parse(json).items as Array<Record<string, any>>;
    const sidebarSep = items.findIndex((i) => i.type === "trackingSeparator" && i.pane === "sidebar");
    expect(sidebarSep).toBeGreaterThanOrEqual(0);
    expect(items.findIndex((i) => i.id === "s1")).toBeLessThan(sidebarSep);
    // The desugared item carries its pane tag through to the wire.
    expect(items.find((i) => i.id === "s1")!.pane).toBe("sidebar");
  });

  // A pane tag pointing at an absent pane is warned + ignored (item falls back
  // to content); no orphan region separator is synthesized. Mirrors the
  // trackingSeparator pane-drop behavior.
  test("pane tag for an absent pane is ignored (no synthesized separator)", () => {
    const warnings: string[] = [];
    const orig = console.warn;
    console.warn = (msg: string) => { warnings.push(String(msg)); };
    let json: string;
    try {
      ({ json } = normalizeToolbar(
        { items: [{ id: "s1", label: "New", pane: "sidebar" }] },
        /*hasSidebar*/ false, /*hasInspector*/ false,
      ));
    } finally { console.warn = orig; }
    const items = JSON.parse(json!).items as Array<Record<string, any>>;
    expect(items.some((i) => i.type === "trackingSeparator")).toBe(false);
    expect(items.find((i) => i.id === "s1")).not.toHaveProperty("pane");
    expect(warnings.some((w) => w.includes('pane:"sidebar"'))).toBe(true);
  });
});

// #771 T8 review I3: router.push's toolbar override used to mint fresh
// __tbmenu_N ids (module-global counter) on every push, orphaning the
// previous push's ids in the app-global action maps — unbounded growth
// across repeated pushes of the same route. normalizeToolbar's optional
// 4th `windowId` arg (only router.push passes it) derives stable
// (windowId, itemId, menu-path-index) ids instead, so re-normalizing the
// same menu tree reuses the same ids and the caller's Map.set() overwrites
// in place rather than growing.
//
// Round 2 (#771 T8 re-review): the (windowId, itemId, index) base was
// stable ACROSS repeated pushes of the SAME route, but had no route
// discriminator — two DIFFERENT routes pushing overrides with the same
// itemId derived the SAME ids and silently overwrote each other's
// menuActions entry (navigate back to route A, tap its menu, route B's
// closure fires). normalizeToolbar's new optional 5th `url` arg folds the
// pushed route's url into the base, so ids are now scoped per (windowId,
// url, itemId, index) — same-route repeats still reuse identical ids;
// different routes now derive disjoint ones.
describe("normalizeToolbar stable menu ids (push path, #771 T8 review I3; round 2: route-scoped)", () => {
  const menuToolbar = {
    items: [
      {
        id: "d-share", label: "Share",
        menu: [
          { label: "Copy Link", action: () => {} },
          { label: "Email", action: () => {} },
        ],
      } as any,
    ],
  };

  test("repeated normalizeToolbar(..., windowId, url) calls for the SAME url reuse the same auto menu ids", () => {
    const first = normalizeToolbar(menuToolbar, false, false, "win-42", "/detail");
    const second = normalizeToolbar(menuToolbar, false, false, "win-42", "/detail");
    const firstIds = [...first.menuActions.keys()].sort();
    const secondIds = [...second.menuActions.keys()].sort();
    expect(firstIds.length).toBe(2);
    expect(secondIds).toEqual(firstIds); // same keys reused, not fresh ones appended
    for (const id of firstIds) expect(id).toMatch(/^__tbmenu_win-42_\/detail_d-share_\d+$/);
  });

  test("round 2: two DIFFERENT urls, same itemId, produce DISTINCT key sets and both routes' actions survive", () => {
    const routeA = {
      items: [{ id: "d-share", label: "Share", menu: [{ label: "Copy", action: () => "A" }] } as any],
    };
    const routeB = {
      items: [{ id: "d-share", label: "Share", menu: [{ label: "Copy", action: () => "B" }] } as any],
    };
    const a = normalizeToolbar(routeA, false, false, "win-42", "/a");
    const b = normalizeToolbar(routeB, false, false, "win-42", "/b");
    const aIds = [...a.menuActions.keys()];
    const bIds = [...b.menuActions.keys()];
    expect(aIds.length).toBe(1);
    expect(bIds.length).toBe(1);
    expect(aIds[0]).not.toBe(bIds[0]); // distinct keys — no cross-route collision

    // Simulate router.push's registration into the shared app-global map:
    // both pushes' menuActions land in ONE Map.set() sequence, additively.
    const menuActions = new Map<string, (ctx?: any) => unknown>();
    for (const [id, fn] of a.menuActions) menuActions.set(id, fn);
    for (const [id, fn] of b.menuActions) menuActions.set(id, fn);
    expect(menuActions.get(aIds[0])?.()).toBe("A"); // route A's closure still reachable at its key
    expect(menuActions.get(bIds[0])?.()).toBe("B"); // route B's closure still reachable at its key
  });

  test("without windowId (setItems/create path), ids keep the original global-counter form", () => {
    const { menuActions } = normalizeToolbar(menuToolbar, false, false);
    const ids = [...menuActions.keys()];
    expect(ids.length).toBe(2);
    for (const id of ids) expect(id).toMatch(/^__tbmenu_\d+$/);
  });
});

