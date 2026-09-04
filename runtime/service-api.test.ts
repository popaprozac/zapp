import { describe, expect, it } from "bun:test";
import {
  PermissionDeniedError as FocusedPermissionDeniedError,
  Services as FocusedServices,
  ZappError as FocusedZappError,
  ZappInvocationError as FocusedZappInvocationError,
} from "./service-api";
import {
  PermissionDeniedError,
  ZappError,
  ZappInvocationError,
} from "./errors";
import { Services } from "./services";

describe("focused service runtime", () => {
  it("preserves the canonical transport and error identities", () => {
    expect(FocusedServices).toBe(Services);
    expect(FocusedZappError).toBe(ZappError);
    expect(FocusedZappInvocationError).toBe(ZappInvocationError);
    expect(FocusedPermissionDeniedError).toBe(PermissionDeniedError);
  });
});
