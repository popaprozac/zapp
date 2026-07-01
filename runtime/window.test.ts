import { describe, expect, test } from "bun:test";
import { Material, BackgroundExtension } from "./window";
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

