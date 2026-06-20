import { describe, it, expect, afterEach } from "bun:test";
import { useNimNative } from "./native-lang";

describe("useNimNative", () => {
  const orig = process.env.ZAPP_NATIVE_LANG;
  afterEach(() => {
    if (orig === undefined) delete process.env.ZAPP_NATIVE_LANG;
    else process.env.ZAPP_NATIVE_LANG = orig;
  });

  it("defaults to Nim when unset", () => {
    delete process.env.ZAPP_NATIVE_LANG;
    expect(useNimNative()).toBe(true);
  });

  it("opts out to zc when ZAPP_NATIVE_LANG=zc", () => {
    process.env.ZAPP_NATIVE_LANG = "zc";
    expect(useNimNative()).toBe(false);
  });

  it("stays Nim for ZAPP_NATIVE_LANG=nim", () => {
    process.env.ZAPP_NATIVE_LANG = "nim";
    expect(useNimNative()).toBe(true);
  });

  it("stays Nim (fail-open) for any other value", () => {
    process.env.ZAPP_NATIVE_LANG = "rust";
    expect(useNimNative()).toBe(true);
  });
});
