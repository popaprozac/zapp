import { describe, expect, test } from "bun:test";
import { errorFromBridgePayload, ZappInvocationError } from "./errors";
import { WindowError } from "./window";
import { RelatedWindowInvalidatedError } from "./window-api";

describe("window bridge errors", () => {
  test("reconstructs a feature-specific error with operation metadata", () => {
    const error = errorFromBridgePayload(JSON.stringify({
      code: "WINDOW_ERROR",
      message: "could not create the native window",
      operation: "create",
      windowId: "win-2",
    }));

    expect(error).toBeInstanceOf(WindowError);
    expect(error).toMatchObject({
      name: "WindowError",
      code: "WINDOW_ERROR",
      message: "could not create the native window",
      operation: "create",
      windowId: "win-2",
    });
  });

  test("reconstructs document invalidation separately from service failures", () => {
    const error = errorFromBridgePayload(JSON.stringify({
      code: "RELATED_WINDOW_INVALIDATED", message: "document gone",
      windowId: "win-child", reason: "The owner navigated away.",
    }));
    expect(error).toBeInstanceOf(RelatedWindowInvalidatedError);
    expect(error).toMatchObject({
      code: "RELATED_WINDOW_INVALIDATED", windowId: "win-child", reason: "The owner navigated away.",
    });
  });

  test("does not manufacture missing or malformed invalidation context", () => {
    for (const fields of [{}, { windowId: "win-child" }, { windowId: 1, reason: "closed" },
      { windowId: "win-child", reason: {} }, { windowId: "win-child", reason: "" }]) {
      const error = errorFromBridgePayload(JSON.stringify({
        code: "RELATED_WINDOW_INVALIDATED", message: "document gone", ...fields,
      }));
      expect(error).toBeInstanceOf(ZappInvocationError);
      expect(error).not.toBeInstanceOf(RelatedWindowInvalidatedError);
    }
  });
});
