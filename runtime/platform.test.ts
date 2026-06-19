import { test, expect } from "bun:test";
import { Platform } from "./platform";

const BOOT = Symbol.for("zapp.bootstrapConfig");

test("Platform.current reads the injected bootstrap manifest platform", () => {
  (globalThis as any)[BOOT] = { permissions: { platform: "ios" } };
  expect(Platform.current()).toBe("ios");
  expect(Platform.isIOS).toBe(true);
  expect(Platform.isMacOS).toBe(false);
  expect(Platform.isWindows).toBe(false);
  delete (globalThis as any)[BOOT];
});

test("Platform.current defaults to macos when no manifest is present", () => {
  delete (globalThis as any)[BOOT];
  expect(Platform.current()).toBe("macos");
  expect(Platform.isMacOS).toBe(true);
});

test("Platform.isWindows for a windows manifest", () => {
  (globalThis as any)[BOOT] = { permissions: { platform: "windows" } };
  expect(Platform.current()).toBe("windows");
  expect(Platform.isWindows).toBe(true);
  delete (globalThis as any)[BOOT];
});
