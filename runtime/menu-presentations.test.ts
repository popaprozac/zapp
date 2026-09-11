import { expect, test } from "bun:test";
import { MenuPresentations } from "./menu-presentations";

test("one command may belong to independent application and popup presentations", () => {
  const registry = new MenuPresentations<object>();
  const shared = {};
  const popupOnly = {};
  registry.add("application", new Map([["rename", shared]]));
  registry.add("popup", new Map([["rename", shared], ["delete", popupOnly]]));
  expect(registry.tokensFor(shared)).toEqual(["application", "popup"]);
  expect(registry.tokensFor(popupOnly)).toEqual(["popup"]);
  expect(registry.command("popup", "rename")).toBe(shared);
  expect(registry.command("application", "delete")).toBeUndefined();

  registry.remove("popup");
  registry.remove("popup");
  expect(registry.tokensFor(shared)).toEqual(["application"]);
  expect(registry.tokensFor(popupOnly)).toEqual([]);
  expect(registry.command("popup", "rename")).toBeUndefined();
  expect(registry.command("application", "rename")).toBe(shared);
});

test("replacing the application presentation does not detach a live popup", () => {
  const registry = new MenuPresentations<object>();
  const command = {};
  registry.add("application-1", new Map([["command", command]]));
  registry.add("popup", new Map([["command", command]]));
  registry.remove("application-1");
  registry.add("application-2", new Map());
  expect(registry.tokensFor(command)).toEqual(["popup"]);
  expect(registry.command("popup", "command")).toBe(command);
  registry.clear();
  expect(registry.tokensFor(command)).toEqual([]);
  expect(registry.command("popup", "command")).toBeUndefined();
});

test("presentation tables are snapshots and owner membership is deduplicated", () => {
  const registry = new MenuPresentations<object>();
  const command = {};
  const input = new Map([["first", command], ["second", command]]);
  registry.add("owner", input);
  input.clear();
  expect(registry.command("owner", "first")).toBe(command);
  expect(registry.tokensFor(command)).toEqual(["owner"]);
  expect(() => registry.add("owner", new Map())).toThrow("already active");
  const tokens = registry.tokensFor(command) as string[];
  tokens.push("forged");
  expect(registry.tokensFor(command)).toEqual(["owner"]);
  registry.remove("owner");
  expect(registry.tokensFor(command)).toEqual([]);
});
