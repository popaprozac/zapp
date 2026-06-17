import { test, expect } from "bun:test";
import { chooseNimRoot } from "./native";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

test("chooseNimRoot prefers the app's zapp/app.nim when present", () => {
  const root = mkdtempSync(path.join(tmpdir(), "zapp-"));
  mkdirSync(path.join(root, "zapp"), { recursive: true });
  writeFileSync(path.join(root, "zapp", "app.nim"), "import zapp\n");
  expect(chooseNimRoot(root, "/native")).toBe(path.join(root, "zapp", "app.nim"));
});

test("chooseNimRoot falls back to the skeleton when no app.nim", () => {
  const root = mkdtempSync(path.join(tmpdir(), "zapp-"));
  expect(chooseNimRoot(root, "/native")).toBe(path.join("/native", "nim", "zapp.nim"));
});
