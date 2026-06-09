import { describe, expect, test } from "bun:test";
import { resolvePermissions, validatePermissions, isPermissionAllowed } from "./permissions";

describe("resolvePermissions", () => {
  test("absent field → inactive (allow-all)", () => {
    const r = resolvePermissions(undefined);
    expect(r.active).toBe(false);
    expect(r.allow).toEqual([]);
  });

  test("present field → active + normalized set", () => {
    const r = resolvePermissions(["clipboard:read", "fs", "clipboard:read"]);
    expect(r.active).toBe(true);
    expect(r.allow).toEqual(["clipboard:read", "fs"]); // deduped, order-preserving
  });

  test("empty array → active, deny-everything", () => {
    const r = resolvePermissions([]);
    expect(r.active).toBe(true);
    expect(r.allow).toEqual([]);
  });
});

describe("validatePermissions", () => {
  test("unknown id is an error with suggestion", () => {
    const errs = validatePermissions(["clipbord" as never]);
    expect(errs.length).toBe(1);
    expect(errs[0]).toContain("clipbord");
    expect(errs[0]).toContain("clipboard"); // did-you-mean
  });

  test("verb alongside its bare module is a warning, not an error", () => {
    const errs = validatePermissions(["clipboard", "clipboard:read"]);
    expect(errs).toEqual([]); // redundancy warns via console, never errors
  });

  test("valid list passes", () => {
    expect(validatePermissions(["fs:read", "dialog", "shell:open"])).toEqual([]);
  });
});

describe("isPermissionAllowed (verb semantics, mirrors native)", () => {
  test("bare module grants its verbs", () => {
    expect(isPermissionAllowed("clipboard:read", { active: true, allow: ["clipboard"] })).toBe(true);
  });
  test("verb grant does not imply sibling verb", () => {
    expect(isPermissionAllowed("clipboard:write", { active: true, allow: ["clipboard:read"] })).toBe(false);
  });
  test("inactive manifest allows everything", () => {
    expect(isPermissionAllowed("tray", { active: false, allow: [] })).toBe(true);
  });
  test("exact verb match", () => {
    expect(isPermissionAllowed("fs:write", { active: true, allow: ["fs:write"] })).toBe(true);
  });
});
