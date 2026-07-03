import { describe, expect, test } from "bun:test";
import { Material, BackgroundExtension, applyToolbarConventions, normalizeToolbar } from "./window";
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

// #771 T8 review I3: router.push's toolbar override used to mint fresh
// __tbmenu_N ids (module-global counter) on every push, orphaning the
// previous push's ids in the app-global action maps — unbounded growth
// across repeated pushes of the same route. normalizeToolbar's optional
// 4th `windowId` arg (only router.push passes it) derives stable
// (windowId, itemId, menu-path-index) ids instead, so re-normalizing the
// same menu tree reuses the same ids and the caller's Map.set() overwrites
// in place rather than growing.
describe("normalizeToolbar stable menu ids (push path, #771 T8 review I3)", () => {
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

  test("repeated normalizeToolbar(..., windowId) calls reuse the same auto menu ids", () => {
    const first = normalizeToolbar(menuToolbar, false, false, "win-42");
    const second = normalizeToolbar(menuToolbar, false, false, "win-42");
    const firstIds = [...first.menuActions.keys()].sort();
    const secondIds = [...second.menuActions.keys()].sort();
    expect(firstIds.length).toBe(2);
    expect(secondIds).toEqual(firstIds); // same keys reused, not fresh ones appended
    for (const id of firstIds) expect(id).toMatch(/^__tbmenu_win-42_d-share_\d+$/);
  });

  test("without windowId (setItems/create path), ids keep the original global-counter form", () => {
    const { menuActions } = normalizeToolbar(menuToolbar, false, false);
    const ids = [...menuActions.keys()];
    expect(ids.length).toBe(2);
    for (const id of ids) expect(id).toMatch(/^__tbmenu_\d+$/);
  });
});

