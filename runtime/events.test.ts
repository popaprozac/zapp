import { test, expect } from "bun:test";
import { AppEvent, eventName } from "./events";

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
