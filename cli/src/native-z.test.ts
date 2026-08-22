import { describe, expect, it } from "bun:test";
import { parseZCompilerIdentity, validateZCompilerIdentity } from "./native-z";

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
