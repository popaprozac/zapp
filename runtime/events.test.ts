import { test, expect, describe } from "bun:test";
import { AppEvent, WindowEvent, eventName } from "./events";

test("new background-app AppEvents map to their wire names", () => {
  expect(eventName(AppEvent.WILL_SLEEP)).toBe("app:will-sleep");
  expect(eventName(AppEvent.DID_WAKE)).toBe("app:did-wake");
  expect(eventName(AppEvent.SCREEN_LOCKED)).toBe("app:screen-locked");
  expect(eventName(AppEvent.SCREEN_UNLOCKED)).toBe("app:screen-unlocked");
  expect(eventName(AppEvent.BEFORE_QUIT)).toBe("app:before-quit");
});

test("existing AppEvent mapping is unchanged", () => {
  expect(eventName(AppEvent.THEME_CHANGED)).toBe("app:theme-changed");
  expect(eventName(AppEvent.REOPEN)).toBe("app:reopen");
});

test("POWER_STATE_CHANGED maps to app:power-state-changed", () => {
  expect(eventName(AppEvent.POWER_STATE_CHANGED)).toBe("app:power-state-changed");
});

test("BATTERY_LEVEL_CHANGED maps to app:battery-level-changed", () => {
  expect(eventName(AppEvent.BATTERY_LEVEL_CHANGED)).toBe("app:battery-level-changed");
});

describe("inspector window events", () => {
  test("INSPECTOR_* map to window:inspector-* wire names", () => {
    expect(eventName(WindowEvent.INSPECTOR_COLLAPSED)).toBe("window:inspector-collapsed");
    expect(eventName(WindowEvent.INSPECTOR_EXPANDED)).toBe("window:inspector-expanded");
    expect(eventName(WindowEvent.INSPECTOR_RESIZED)).toBe("window:inspector-resized");
  });
});
