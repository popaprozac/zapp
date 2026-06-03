import { test, expect } from "bun:test";
import { setCliLevel, levelFromArgv, envFromLevel } from "./log";

test("levelFromArgv maps flags to levels", () => {
  expect(levelFromArgv(["dev"])).toBe(0);
  expect(levelFromArgv(["dev", "--verbose"])).toBe(1);
  expect(levelFromArgv(["dev", "-v"])).toBe(1);
  expect(levelFromArgv(["dev", "--debug"])).toBe(2);
  // debug wins over verbose if both present
  expect(levelFromArgv(["dev", "--verbose", "--debug"])).toBe(2);
});

test("envFromLevel maps level to ZAPP_LOG value", () => {
  expect(envFromLevel(0)).toBe("");
  expect(envFromLevel(1)).toBe("verbose");
  expect(envFromLevel(2)).toBe("debug");
});

test("setCliLevel / getCliLevel round-trip", async () => {
  const { getCliLevel } = await import("./log");
  setCliLevel(2);
  expect(getCliLevel()).toBe(2);
  setCliLevel(0);
  expect(getCliLevel()).toBe(0);
});
