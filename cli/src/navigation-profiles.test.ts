import { describe, expect, it } from "bun:test";
import { resolveNavigationProfiles } from "./navigation-profiles";

describe("navigation profiles", () => {
  it("defaults to a self-only WebView ceiling", () => {
    expect(resolveNavigationProfiles({})).toEqual([{
      name: "default",
      allowsSelf: true,
      origins: [],
      externalSchemes: [],
    }]);
  });

  it("normalizes configured origins and external schemes", () => {
    expect(resolveNavigationProfiles({
      navigationProfiles: {
        default: {
          navigate: ["self", "HTTPS://DOCS.EXAMPLE.COM:443"],
          openExternal: ["HTTPS:", "mailto:"],
        },
      },
    })).toEqual([{
      name: "default",
      allowsSelf: true,
      origins: ["https://docs.example.com"],
      externalSchemes: ["https:", "mailto:"],
    }]);
  });
});
