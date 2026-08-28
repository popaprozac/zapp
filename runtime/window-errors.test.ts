import { describe, expect, test } from "bun:test";
import { errorFromBridgePayload } from "./errors";
import { WindowError } from "./window";

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
});
