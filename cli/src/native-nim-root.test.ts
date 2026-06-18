import { test, expect } from "bun:test";
import { chooseNimRoot } from "./native";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

test("chooseNimRoot resolves the app's zapp/app.nim when present", () => {
  const root = mkdtempSync(path.join(tmpdir(), "zapp-"));
  mkdirSync(path.join(root, "zapp"), { recursive: true });
  writeFileSync(path.join(root, "zapp", "app.nim"), "import zapp\n");
  expect(chooseNimRoot(root)).toBe(path.join(root, "zapp", "app.nim"));
});

test("chooseNimRoot throws when no app.nim (required native entry, no skeleton fallback)", () => {
  const root = mkdtempSync(path.join(tmpdir(), "zapp-"));
  expect(() => chooseNimRoot(root)).toThrow(/no native entry/);
});
