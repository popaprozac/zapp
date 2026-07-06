import { test, expect } from "bun:test";
import {
  resolveNative, validateNative, validateWebEngine, resolveWebEngine,
  platformSupportsChromium, resolveWebEngineForBuild,
} from "./config";

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

// webEngine: "chromium" is now an accepted early-access opt-in (CEF
// production slice) — it silently accepts (no throw), no longer warns here.
// "system"/unset stay the default; unknown values still throw. See
// resolveWebEngine below for the single-source-of-truth resolver the build +
// window creation both read.
test("validateWebEngine accepts \"chromium\" (no throw, no longer warns)", () => {
  expect(() => validateWebEngine("chromium")).not.toThrow();
});

test("validateWebEngine accepts \"system\" and unset", () => {
  expect(() => validateWebEngine("system")).not.toThrow();
  expect(() => validateWebEngine(undefined)).not.toThrow();
});

test("validateWebEngine still rejects unknown values", () => {
  expect(() => validateWebEngine("blink" as any)).toThrow(/webEngine/);
});

// --- resolveWebEngine: string form applies to every target ---
test("resolveWebEngine string form applies to all targets", () => {
  expect(resolveWebEngine({ webEngine: "chromium" } as any, "macos")).toBe("chromium");
  expect(resolveWebEngine({ webEngine: "chromium" } as any, "windows")).toBe("chromium");
  expect(resolveWebEngine({ webEngine: "system" } as any, "macos")).toBe("system");
});

test("resolveWebEngine defaults to system when unset", () => {
  expect(resolveWebEngine({} as any, "macos")).toBe("system");
  expect(resolveWebEngine({} as any, "windows")).toBe("system");
});

// --- resolveWebEngine: map form resolves per platform, missing key => system ---
test("resolveWebEngine map form resolves per platform", () => {
  const cfg = { webEngine: { macos: "chromium", windows: "system" } } as any;
  expect(resolveWebEngine(cfg, "macos")).toBe("chromium");
  expect(resolveWebEngine(cfg, "windows")).toBe("system");
});

test("resolveWebEngine map form: missing key defaults to system", () => {
  const cfg = { webEngine: { macos: "chromium" } } as any; // no windows/ios key
  expect(resolveWebEngine(cfg, "windows")).toBe("system");
  expect(resolveWebEngine(cfg, "ios-simulator")).toBe("system");
});

test("resolveWebEngine collapses both iOS subtargets to the ios key", () => {
  const cfg = { webEngine: { ios: "chromium" } } as any;
  expect(resolveWebEngine(cfg, "ios-simulator")).toBe("chromium");
  expect(resolveWebEngine(cfg, "ios-device")).toBe("chromium");
});

// --- platformSupportsChromium: macOS only today ---
test("platformSupportsChromium is macOS-only today", () => {
  expect(platformSupportsChromium("macos")).toBe(true);
  expect(platformSupportsChromium("windows")).toBe(false);
  expect(platformSupportsChromium("ios-simulator")).toBe(false);
  expect(platformSupportsChromium("ios-device")).toBe(false);
});

// --- resolveWebEngineForBuild: downgrade chromium -> system on unsupported target ---
test("resolveWebEngineForBuild keeps chromium on macOS", () => {
  expect(resolveWebEngineForBuild({ webEngine: "chromium" } as any, "macos"))
    .toEqual({ engine: "chromium", downgraded: false });
});

test("resolveWebEngineForBuild downgrades chromium to system on an unsupported target", () => {
  expect(resolveWebEngineForBuild({ webEngine: { windows: "chromium" } } as any, "windows"))
    .toEqual({ engine: "system", downgraded: true });
});

test("resolveWebEngineForBuild leaves system alone everywhere", () => {
  expect(resolveWebEngineForBuild({} as any, "windows"))
    .toEqual({ engine: "system", downgraded: false });
});

// --- validateWebEngine: accepts string + map, throws on garbage ---
test("validateWebEngine accepts string and map forms", () => {
  expect(() => validateWebEngine("chromium")).not.toThrow();
  expect(() => validateWebEngine("system")).not.toThrow();
  expect(() => validateWebEngine(undefined)).not.toThrow();
  expect(() => validateWebEngine({ macos: "chromium", windows: "system" } as any)).not.toThrow();
});

test("validateWebEngine throws on a garbage value in either form", () => {
  expect(() => validateWebEngine("blink" as any)).toThrow(/webEngine/);
  expect(() => validateWebEngine({ windows: "blink" } as any)).toThrow(/webEngine/);
});
