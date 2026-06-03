import { test, expect } from "bun:test";
import { resolveNative } from "./config";

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
