import { describe, expect, test } from "bun:test";
import {
  PermissionDeniedError,
  ZappError,
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
    expect(error).toBeInstanceOf(ZappError);
    expect(error).not.toBeInstanceOf(ZappInvocationError);
    expect(error).toMatchObject({
      name: "PermissionDeniedError",
      code: "PERMISSION_DENIED",
      permission: "window:create",
      message: "window creation is disabled",
    });
  });

  test("retains stable codes for other native invocation failures", () => {
    const error = errorFromBridgePayload(JSON.stringify({
      code: "SERVICE_ERROR",
      message: "the native service failed",
      permission: "",
    }));
    expect(error).toBeInstanceOf(ZappInvocationError);
    expect(error).toBeInstanceOf(ZappError);
    expect(error).toMatchObject({
      name: "ZappInvocationError",
      code: "SERVICE_ERROR",
      message: "the native service failed",
    });
  });

  test("retains typed Z service error identity and decoded details", () => {
    const error = errorFromBridgePayload(JSON.stringify({
      code: "SERVICE_ERROR",
      message: "notes.create threw NoteCreationError",
      service: "notes",
      method: "create",
      errorType: "NoteCreationError",
      details: JSON.stringify({ message: "a title is required", title: "" }),
    }));
    expect(error).toBeInstanceOf(ZappInvocationError);
    expect(error).toMatchObject({
      service: "notes",
      method: "create",
      errorType: "NoteCreationError",
      details: { message: "a title is required", title: "" },
    });
  });
});
