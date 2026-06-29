import { describe, expect, test } from "bun:test";
import { routeForSection, sectionForRoute } from "./route-map";

describe("route-map", () => {
  test("home maps to '/' both ways", () => {
    expect(routeForSection("home")).toBe("/");
    expect(sectionForRoute("/")).toBe("home");
    expect(sectionForRoute("")).toBe("home");
  });
  test("a section maps to '/<id>' both ways", () => {
    expect(routeForSection("toolbar")).toBe("/toolbar");
    expect(sectionForRoute("/toolbar")).toBe("toolbar");
  });
  test("round-trips section ids", () => {
    for (const id of ["home", "sidebar", "toolbar", "workers", "tray"]) {
      expect(sectionForRoute(routeForSection(id))).toBe(id);
    }
  });
});
