import { describe, expect, it } from "bun:test";
import {
  parseZCompilerIdentity,
  renderZWebviewBootstrapC,
  resolveZNativeHost,
  validateZCompilerIdentity,
} from "./native-z";

describe("renderZWebviewBootstrapC", () => {
  it("preserves arbitrary UTF-8 source without C literal ambiguity", () => {
    const source = 'globalThis.message = "héllo\\n世界";\u2028';
    const output = renderZWebviewBootstrapC(source);
    const bytes = Array.from(
      output.matchAll(/\\x([0-9a-f]{2})/g),
      (match) => Number.parseInt(match[1], 16),
    );

    expect(new TextDecoder().decode(Uint8Array.from(bytes))).toBe(source);
    expect(output).toContain("const char *zapp_webview_bootstrap_script(void)");
  });

  it("emits a valid empty C string", () => {
    expect(renderZWebviewBootstrapC(""))
      .toContain('static const char zapp_webview_bootstrap[] =\n  "";');
  });
});

describe("resolveZNativeHost", () => {
  it("selects the visible desktop host by default", () => {
    expect(resolveZNativeHost(undefined)).toBe("desktop");
  });

  it("allows the strict C bridge regression host", () => {
    expect(resolveZNativeHost("bridge")).toBe("bridge");
  });

  it("rejects unknown host modes", () => {
    expect(() => resolveZNativeHost("other"))
      .toThrow(/ZAPP_Z_HOST must be "desktop" or "bridge"/);
  });
});

describe("parseZCompilerIdentity", () => {
  it("decodes the pinned compiler contract", () => {
    expect(parseZCompilerIdentity("z 0.1.0-dev revision 2026-08-22 compiler-api 1\n"))
      .toEqual({
        languageVersion: "0.1.0-dev",
        compilerRevision: "2026-08-22",
        compilerApi: 1,
      });
  });

  it("rejects an unversioned compiler", () => {
    expect(() => parseZCompilerIdentity("unknown z compiler command version\n"))
      .toThrow(/requires a compiler that supports `z version`/);
  });
});

describe("validateZCompilerIdentity", () => {
  const expected = {
    languageVersion: "0.1.0-dev",
    compilerRevision: "2026-08-22",
    compilerApi: 1,
  };

  it("accepts the exact pinned identity", () => {
    expect(() => validateZCompilerIdentity(expected, expected, "compiler-contract.json"))
      .not.toThrow();
  });

  it("reports every incompatible compiler dimension", () => {
    expect(() => validateZCompilerIdentity(expected, {
      languageVersion: "0.2.0-dev",
      compilerRevision: "later",
      compilerApi: 2,
    }, "compiler-contract.json")).toThrow(
      /language 0\.2\.0-dev.*revision later.*compiler API 2.*compiler-contract\.json/,
    );
  });
});
