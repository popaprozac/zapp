import { describe, it, expect, afterEach } from "bun:test";
import { nativeLanguage } from "./native-lang";

describe("nativeLanguage", () => {
  const orig = process.env.ZAPP_NATIVE_LANG;
  afterEach(() => {
    if (orig === undefined) delete process.env.ZAPP_NATIVE_LANG;
    else process.env.ZAPP_NATIVE_LANG = orig;
  });

  it("defaults to Nim when unset", () => {
    delete process.env.ZAPP_NATIVE_LANG;
    expect(nativeLanguage()).toBe("nim");
  });

  it("opts out to zc when ZAPP_NATIVE_LANG=zc", () => {
    process.env.ZAPP_NATIVE_LANG = "zc";
    expect(nativeLanguage()).toBe("zc");
  });

  it("stays Nim for ZAPP_NATIVE_LANG=nim", () => {
    process.env.ZAPP_NATIVE_LANG = "nim";
    expect(nativeLanguage()).toBe("nim");
  });

  it("selects the replacement core for ZAPP_NATIVE_LANG=z", () => {
    process.env.ZAPP_NATIVE_LANG = "z";
    expect(nativeLanguage()).toBe("z");
  });

  it("fails closed for any other value", () => {
    process.env.ZAPP_NATIVE_LANG = "rust";
    expect(() => nativeLanguage()).toThrow(/Expected "nim", "zc", or "z"/);
  });
});
