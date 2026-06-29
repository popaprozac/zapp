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

test("Platform.os mirrors current()", () => {
  (globalThis as any)[BOOT] = { permissions: { platform: "ios" } };
  expect(Platform.os).toBe("ios");
  delete (globalThis as any)[BOOT];
});

test("Platform.formFactor + booleans read the injected formFactor", () => {
  (globalThis as any)[BOOT] = { permissions: { platform: "ios" }, formFactor: "tablet" };
  expect(Platform.formFactor).toBe("tablet");
  expect(Platform.isTablet).toBe(true);
  expect(Platform.isPhone).toBe(false);
  expect(Platform.isDesktop).toBe(false);
  delete (globalThis as any)[BOOT];
});

test("Platform.formFactor defaults to desktop when absent", () => {
  (globalThis as any)[BOOT] = { permissions: { platform: "macos" } };
  expect(Platform.formFactor).toBe("desktop");
  expect(Platform.isDesktop).toBe(true);
  delete (globalThis as any)[BOOT];
});

test("Platform.env + booleans read the injected env", () => {
  (globalThis as any)[BOOT] = { permissions: { platform: "ios" }, env: "dev" };
  expect(Platform.env).toBe("dev");
  expect(Platform.isDev).toBe(true);
  expect(Platform.isProd).toBe(false);
  delete (globalThis as any)[BOOT];
});

test("Platform.env defaults to prod when absent", () => {
  delete (globalThis as any)[BOOT];
  expect(Platform.env).toBe("prod");
  expect(Platform.isProd).toBe(true);
});

test("Platform reads a worker-shaped bootstrapConfig (os + formFactor + env)", () => {
  (globalThis as any)[Symbol.for("zapp.bootstrapConfig")] = {
    permissions: { platform: "ios" },
    formFactor: "phone",
    env: "dev",
  };
  expect(Platform.os).toBe("ios");
  expect(Platform.isIOS).toBe(true);
  expect(Platform.formFactor).toBe("phone");
  expect(Platform.isPhone).toBe(true);
  expect(Platform.env).toBe("dev");
  expect(Platform.isDev).toBe(true);
  delete (globalThis as any)[Symbol.for("zapp.bootstrapConfig")];
});

test("Platform defaults hold when no config (worker before/without carrier)", () => {
  delete (globalThis as any)[Symbol.for("zapp.bootstrapConfig")];
  expect(Platform.os).toBe("macos");
  expect(Platform.formFactor).toBe("desktop");
  expect(Platform.env).toBe("prod");
});
