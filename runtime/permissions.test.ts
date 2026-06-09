import { describe, expect, test } from "bun:test";
import {
  isAllowedByManifest, supportStatus, PermissionDeniedError,
  type PermissionsManifest,
} from "./permissions";

const m = (active: boolean, allow: string[]): PermissionsManifest =>
  ({ platform: "macos", active, allow });

describe("isAllowedByManifest (verb semantics)", () => {
  test("inactive allows all", () => expect(isAllowedByManifest("tray", m(false, []))).toBe(true));
  test("bare grants verbs", () => expect(isAllowedByManifest("fs:read", m(true, ["fs"]))).toBe(true));
  test("verb is exact", () => expect(isAllowedByManifest("fs:write", m(true, ["fs:read"]))).toBe(false));
  test("missing manifest treated as inactive", () => expect(isAllowedByManifest("tray", undefined)).toBe(true));
});

describe("supportStatus (platform axis)", () => {
  test("tray unsupported on ios", () => expect(supportStatus("tray", "ios")).toBe("unsupported"));
  test("shortcuts unsupported on ios", () => expect(supportStatus("shortcuts", "ios")).toBe("unsupported"));
  test("clipboard supported on ios", () => expect(supportStatus("clipboard:read", "ios")).toBe("supported"));
  test("tray supported on macos", () => expect(supportStatus("tray", "macos")).toBe("supported"));
  test("verb resolves via its module", () => expect(supportStatus("menu", "ios")).toBe("unsupported"));
});

describe("PermissionDeniedError", () => {
  test("carries code + permission", () => {
    const e = new PermissionDeniedError("clipboard:write");
    expect(e.code).toBe("PERMISSION_DENIED");
    expect(e.permission).toBe("clipboard:write");
    expect(e.message).toContain("clipboard:write");
  });
});
