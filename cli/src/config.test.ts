import { test, expect } from "bun:test";
import { resolveNative, validateNative } from "./config";

test("resolveNative reads the grouped native block", () => {
  const cfg = { native: { frameworks: ["CoreLocation"], linkFlags: ["-lfoo"], sources: ["a.m"] } } as any;
  expect(resolveNative(cfg, "macos")).toEqual({
    frameworks: ["CoreLocation"], linkFlags: ["-lfoo"], sources: ["a.m"],
  });
});

test("resolveNative falls back to the deprecated flat fields", () => {
  const cfg = { extraFrameworks: ["Contacts"], extraLinkFlags: ["-lbar"], nativeSources: ["b.c"] } as any;
  expect(resolveNative(cfg, "macos")).toEqual({
    frameworks: ["Contacts"], linkFlags: ["-lbar"], sources: ["b.c"],
  });
});

test("resolveNative merges grouped + flat (grouped first, then flat, deduped)", () => {
  const cfg = { native: { frameworks: ["A"] }, extraFrameworks: ["A", "B"] } as any;
  expect(resolveNative(cfg, "macos").frameworks).toEqual(["A", "B"]);
});

test("resolveNative resolves per-platform PlatformValue maps for the target", () => {
  const cfg = { native: { frameworks: { macos: ["MacFW"], ios: ["IosFW"] } } } as any;
  expect(resolveNative(cfg, "macos").frameworks).toEqual(["MacFW"]);
  expect(resolveNative(cfg, "ios-simulator").frameworks).toEqual(["IosFW"]);
});

test("resolveNative returns empty arrays when nothing is set", () => {
  expect(resolveNative({} as any, "macos")).toEqual({ frameworks: [], linkFlags: [], sources: [] });
});

test("validateNative accepts arrays + per-platform maps", () => {
  expect(() => validateNative({ native: { frameworks: ["A"], linkFlags: ["-lx"] } } as any)).not.toThrow();
  expect(() => validateNative({ native: { frameworks: { macos: ["A"], ios: ["B"] } } } as any)).not.toThrow();
  expect(() => validateNative({} as any)).not.toThrow();
});

test("validateNative rejects a non-array / non-map value", () => {
  expect(() => validateNative({ native: { frameworks: "CoreLocation" } } as any)).toThrow(/native\.frameworks/);
});

test("validateNative rejects non-string array entries", () => {
  expect(() => validateNative({ native: { linkFlags: [1, 2] } } as any)).toThrow(/native\.linkFlags/);
});
