import { test, expect } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { resolveIOSIconPng } from "./paths";

function tmpRoot(): string { return mkdtempSync(path.join(tmpdir(), "zapp-iosicon-")); }
function touch(p: string) { mkdirSync(path.dirname(p), { recursive: true }); writeFileSync(p, "x"); }

test("resolveIOSIconPng: a .png config.ios.icon wins", () => {
  const root = tmpRoot();
  touch(path.join(root, "myicon.png"));
  touch(path.join(root, "build", "ios", "icon.png"));
  expect(resolveIOSIconPng(root, { ios: { icon: "myicon.png" } })).toBe(path.join(root, "myicon.png"));
});

test("resolveIOSIconPng: build/ios/icon.png is next", () => {
  const root = tmpRoot();
  touch(path.join(root, "build", "ios", "icon.png"));
  touch(path.join(root, "build", "icon.png"));
  expect(resolveIOSIconPng(root, {})).toBe(path.join(root, "build", "ios", "icon.png"));
});

test("resolveIOSIconPng: build/icon.png is next", () => {
  const root = tmpRoot();
  touch(path.join(root, "build", "icon.png"));
  touch(path.join(root, "build", "macos", "icon.png"));
  expect(resolveIOSIconPng(root, {})).toBe(path.join(root, "build", "icon.png"));
});

test("resolveIOSIconPng: reuses a macOS .png", () => {
  const root = tmpRoot();
  touch(path.join(root, "build", "macos", "icon.png"));
  expect(resolveIOSIconPng(root, {})).toBe(path.join(root, "build", "macos", "icon.png"));
});

test("resolveIOSIconPng: reuses config.macos.icon when it's a .png", () => {
  const root = tmpRoot();
  touch(path.join(root, "brand.png"));
  expect(resolveIOSIconPng(root, { macos: { icon: "brand.png" } })).toBe(path.join(root, "brand.png"));
});

test("resolveIOSIconPng: a non-.png config.ios.icon is ignored and falls through", () => {
  const root = tmpRoot();
  touch(path.join(root, "logo.icns"));
  touch(path.join(root, "build", "macos", "icon.png"));
  expect(resolveIOSIconPng(root, { ios: { icon: "logo.icns" } })).toBe(path.join(root, "build", "macos", "icon.png"));
});
