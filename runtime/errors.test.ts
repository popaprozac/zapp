import { describe, expect, test } from "bun:test";
import {
  PermissionDeniedError,
  ZappInvocationError,
  errorFromBridgePayload,
} from "./errors";

describe("structured bridge errors", () => {
  test("reconstructs permission failures as the public subclass", () => {
    const error = errorFromBridgePayload(JSON.stringify({
      code: "PERMISSION_DENIED",
      message: "window creation is disabled",
      permission: "window:create",
    }));
    expect(error).toBeInstanceOf(PermissionDeniedError);
    expect(error).toMatchObject({
      name: "PermissionDeniedError",
      code: "PERMISSION_DENIED",
      permission: "window:create",
      message: "window creation is disabled",
    });
  });

  test("retains stable codes for other native invocation failures", () => {
    const error = errorFromBridgePayload(JSON.stringify({
      code: "WINDOW_ERROR",
      message: "could not create the native window",
      permission: "",
    }));
    expect(error).toBeInstanceOf(ZappInvocationError);
    expect(error).toMatchObject({
      name: "ZappInvocationError",
      code: "WINDOW_ERROR",
      message: "could not create the native window",
    });
  });
});
