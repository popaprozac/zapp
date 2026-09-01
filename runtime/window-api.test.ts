import { expect, test } from "bun:test";
import * as windowAPI from "./window-api";
import {
  WindowEvent,
  type WindowEventSubscription,
  type WindowHandle,
} from "./window-api";

test("focused window package exports only composed runtime values", () => {
  expect(Object.keys(windowAPI).sort()).toEqual([
    "WindowError",
    "WindowEvent",
    "createWindow",
    "currentWindow",
  ]);
  expect(WindowEvent).toEqual({ FOCUS: 1, BLUR: 2, RESIZE: 3 });
  expect("Window" in windowAPI).toBe(false);
});

test("focused WindowHandle retains typed event payloads and subscriptions", () => {
  const compile = (window: WindowHandle) => {
    const focused: WindowEventSubscription = window.subscribe(
      WindowEvent.FOCUS,
      (payload) => void payload.windowId,
    );
    const resized: WindowEventSubscription = window.subscribe(
      WindowEvent.RESIZE,
      (payload) => void payload.size.width,
    );
    focused.unsubscribe();
    resized.unsubscribe();
  };
  expect(typeof compile).toBe("function");
});

test("package export resolves the focused window facade", async () => {
  const manifest = await Bun.file(
    new URL("./package.json", import.meta.url),
  ).json() as { exports: Record<string, string> };
  expect(manifest.exports["./window"]).toBe("./window-api.ts");
});
