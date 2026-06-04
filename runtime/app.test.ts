import { test, expect } from "bun:test";
import { App } from "./app";

test("getPowerState returns the inert default outside a Zapp webview", () => {
  expect(App.getPowerState()).toEqual({
    source: "ac",
    lowPowerMode: false,
    percent: null,
    charging: false,
  });
});
