import { describe, expect, test } from "bun:test";
import { normalizeAnchor, normalizePopoverOptions } from "./window";

describe("normalizeAnchor", () => {
  test("element-like → measured rect", () => {
    const el = { getBoundingClientRect: () => ({ left: 10, top: 20, width: 80, height: 30 }) };
    expect(normalizeAnchor(el as any)).toEqual({ x: 10, y: 20, width: 80, height: 30 });
  });

  test("mouse-event-like → 1x1 point rect", () => {
    const ev = { clientX: 100, clientY: 250 };
    expect(normalizeAnchor(ev as any)).toEqual({ x: 100, y: 250, width: 1, height: 1 });
  });

  test("rect passthrough with width/height defaults", () => {
    expect(normalizeAnchor({ x: 5, y: 6 })).toEqual({ x: 5, y: 6, width: 1, height: 1 });
    expect(normalizeAnchor({ x: 5, y: 6, width: 40, height: 8 }))
      .toEqual({ x: 5, y: 6, width: 40, height: 8 });
  });

  test("garbage throws", () => {
    expect(() => normalizeAnchor({} as any)).toThrow(/invalid anchor/);
    expect(() => normalizeAnchor(null as any)).toThrow(/invalid anchor/);
  });
});

describe("normalizePopoverOptions", () => {
  test("defaults applied", () => {
    expect(normalizePopoverOptions({ url: "#p" }))
      .toEqual({ url: "#p", width: 320, height: 400, behavior: "transient" });
  });

  test("explicit values pass through", () => {
    expect(normalizePopoverOptions({ url: "#p", width: 200, height: 150, behavior: "semitransient" }))
      .toEqual({ url: "#p", width: 200, height: 150, behavior: "semitransient" });
  });

  test("missing url throws", () => {
    expect(() => normalizePopoverOptions({} as any)).toThrow(/"url" is required/);
  });

  test("bad behavior throws", () => {
    expect(() => normalizePopoverOptions({ url: "#p", behavior: "weird" as any }))
      .toThrow(/invalid behavior/);
  });
});
