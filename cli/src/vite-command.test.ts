import { afterEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { resolveViteCommand } from "./vite-command";

const directories: string[] = [];
function directory(): string {
  const root = realpathSync(mkdtempSync(resolve(tmpdir(), "zapp vite resolver-")));
  directories.push(root);
  return root;
}
function install(root: string, bin: string | { vite: string } = { vite: "bin/vite.js" }): string {
  const pkg = resolve(root, "node_modules/vite");
  mkdirSync(resolve(pkg, "bin"), { recursive: true });
  writeFileSync(resolve(pkg, "package.json"), JSON.stringify({ name: "vite", bin }));
  const entry = resolve(pkg, typeof bin === "string" ? bin : bin.vite);
  writeFileSync(entry, "// fixture CLI\n");
  return entry;
}
afterEach(() => {
  for (const root of directories.splice(0)) rmSync(root, { recursive: true, force: true });
});

test("Vite command uses the project install and preserves arguments with spaces", () => {
  const root = directory();
  const entry = install(root);
  expect(resolveViteCommand(root, ["build", "--outDir", "output with spaces"]))
    .toEqual(["node", entry, "build", "--outDir", "output with spaces"]);
});

test("Vite command resolves a workspace-root dependency from a nested app", () => {
  const root = directory();
  const entry = install(root, "bin/vite.js");
  const app = resolve(root, "spikes/notes");
  mkdirSync(app, { recursive: true });
  writeFileSync(resolve(app, "package.json"), '{"name":"notes"}');
  expect(resolveViteCommand(app, ["--port", "5173", "--strictPort"]))
    .toEqual(["node", entry, "--port", "5173", "--strictPort"]);
});

test("Vite command prefers the application install over the workspace version", () => {
  const root = directory();
  install(root);
  const app = resolve(root, "applications/notes");
  const entry = install(app);
  expect(resolveViteCommand(app, ["build"])).toEqual(["node", entry, "build"]);
});

test("missing Vite fails without a package runner or download fallback", () => {
  expect(() => resolveViteCommand(directory(), ["build"]))
    .toThrow("Zapp will not download an unpinned Vite");
});

test("an incomplete Vite install produces an actionable error", () => {
  const root = directory();
  const entry = install(root);
  rmSync(entry);
  expect(() => resolveViteCommand(root, ["build"]))
    .toThrow("Installed Vite CLI is missing");
});

test("a Vite package without its bin declaration fails clearly", () => {
  const root = directory();
  install(root);
  writeFileSync(resolve(root, "node_modules/vite/package.json"), '{"name":"vite"}');
  expect(() => resolveViteCommand(root, ["build"]))
    .toThrow("Installed Vite has no CLI entry");
});
