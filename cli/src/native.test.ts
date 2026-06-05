import { test, expect } from "bun:test";
import { detectTarget, isIOSTarget } from "./native";

test("detectTarget: --platform ios → ios-simulator", () => {
  expect(detectTarget(["--platform", "ios"])).toBe("ios-simulator");
});
test("detectTarget: --platform ios-simulator", () => {
  expect(detectTarget(["--platform", "ios-simulator"])).toBe("ios-simulator");
});
test("detectTarget: --platform ios-device", () => {
  expect(detectTarget(["--platform", "ios-device"])).toBe("ios-device");
});
test("detectTarget: --platform macos", () => {
  expect(detectTarget(["--platform", "macos"])).toBe("macos");
});
test("detectTarget: unknown --platform throws", () => {
  expect(() => detectTarget(["--platform", "bogus"])).toThrow();
});
test("isIOSTarget classifies the iOS variants", () => {
  expect(isIOSTarget("ios-simulator")).toBe(true);
  expect(isIOSTarget("ios-device")).toBe(true);
  expect(isIOSTarget("macos")).toBe(false);
  expect(isIOSTarget("windows")).toBe(false);
});
