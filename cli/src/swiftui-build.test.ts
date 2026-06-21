import { test, expect } from "bun:test";
import { resolveSwiftUIBuild } from "./swiftui-build";

const base = { swiftLibDir: "/proj/.zapp", swiftcAvailable: true, swiftuiConfig: undefined as boolean | undefined };

test("macOS + toolchain + default config → enabled with defines + link flags", () => {
  const p = resolveSwiftUIBuild({ ...base, target: "macos" });
  expect(p.enabled).toBe(true);
  expect(p.reason).toBe("enabled");
  expect(p.nimArgs).toContain("-d:zappSwiftUI");
  expect(p.nimArgs).toContain("--passC:-DZAPP_HAS_SWIFTUI");
  const link = p.nimArgs.find((a) => a.startsWith("--passL:")) ?? "";
  expect(link).toContain("-lzappswift");
  expect(link).toContain("-lswiftCore");
  expect(link).toContain("-rpath");
  expect(link).toContain("/usr/lib/swift");
  expect(link).toContain("-framework SwiftUI");
  expect(link).toContain("/proj/.zapp");
});

test("macOS + explicit opt-out → disabled, no swiftc, no defines", () => {
  const p = resolveSwiftUIBuild({ ...base, target: "macos", swiftuiConfig: false });
  expect(p.enabled).toBe(false);
  expect(p.reason).toBe("disabled-opt-out");
  expect(p.runSwiftc).toBe(false);
  expect(p.nimArgs).toEqual([]);
});

test("macOS but swiftc missing → disabled (skipped), no defines", () => {
  const p = resolveSwiftUIBuild({ ...base, target: "macos", swiftcAvailable: false });
  expect(p.enabled).toBe(false);
  expect(p.reason).toBe("skipped-no-swiftc");
  expect(p.runSwiftc).toBe(false);
  expect(p.nimArgs).toEqual([]);
});

test("iOS target → disabled (non-macos this cycle)", () => {
  const p = resolveSwiftUIBuild({ ...base, target: "ios-simulator" });
  expect(p.enabled).toBe(false);
  expect(p.reason).toBe("non-macos");
  expect(p.runSwiftc).toBe(false);
});

test("enabled implies runSwiftc true", () => {
  const p = resolveSwiftUIBuild({ ...base, target: "macos" });
  expect(p.runSwiftc).toBe(true);
});
