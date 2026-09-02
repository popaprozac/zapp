import { afterEach, describe, expect, test } from "bun:test";
import { PermissionDeniedError } from "./errors";
import { Services } from "./services";

const previousHostBridge = (globalThis as any).__zappBridge;
const previousDirectInvoke = (globalThis as any).__zappWorkerInvokeService;

afterEach(() => {
  if (previousHostBridge === undefined) delete (globalThis as any).__zappBridge;
  else (globalThis as any).__zappBridge = previousHostBridge;
  if (previousDirectInvoke === undefined) {
    delete (globalThis as any).__zappWorkerInvokeService;
  } else {
    (globalThis as any).__zappWorkerInvokeService = previousDirectInvoke;
  }
});

describe("environment-neutral service invocation", () => {
  test("uses the direct worker host beneath the ordinary Promise API", async () => {
    const calls: Array<{ method: string; args: unknown }> = [];
    (globalThis as any).__zappBridge = {
      invokeService(method: string, args: unknown) {
        calls.push({ method, args });
        return { status: "ready" };
      },
    };

    const result = Services.invoke<{ status: string }, { probe: number }>(
      "health.status",
      { probe: 42 },
    );
    expect(result.cancel).toBeFunction();
    await expect(result).resolves.toEqual({ status: "ready" });
    expect(calls).toEqual([{
      method: "health.status",
      args: { probe: 42 },
    }]);
  });

  test("preserves structured bridge errors on the direct worker path", async () => {
    (globalThis as any).__zappBridge = {
      invokeService() {
        throw JSON.stringify({
          code: "PERMISSION_DENIED",
          message: "worker cannot call notes.create",
          permission: "service:notes.create",
          workerId: "indexer",
        });
      },
    };

    const result = Services.invoke("notes.create", {});
    await expect(result).rejects.toBeInstanceOf(PermissionDeniedError);
    await expect(result).rejects.toMatchObject({
      code: "PERMISSION_DENIED",
      permission: "service:notes.create",
    });
  });

  test("honors an aborted signal before entering a direct native service", async () => {
    let calls = 0;
    (globalThis as any).__zappBridge = {
      invokeService() {
        calls += 1;
        return 42;
      },
    };

    const controller = new AbortController();
    controller.abort();
    const result = Services.invoke("probe.value", undefined, {
      signal: controller.signal,
    });
    await expect(result).rejects.toMatchObject({ name: "AbortError" });
    expect(calls).toBe(0);
  });

  test("starts a direct native service before returning its Promise", async () => {
    let entered = false;
    (globalThis as any).__zappBridge = {
      invokeService() {
        entered = true;
        return 42;
      },
    };

    const result = Services.invoke<number>("probe.value");
    expect(entered).toBeTrue();
    result.cancel();
    await expect(result).resolves.toBe(42);
  });

  test("prefers the native worker intrinsic without changing the service API", async () => {
    const calls: string[] = [];
    (globalThis as any).__zappWorkerInvokeService = (method: string) => {
      calls.push(method);
      return "ready";
    };
    (globalThis as any).__zappBridge = {
      invokeService() {
        throw new Error("the compatibility bridge should not be selected");
      },
    };

    await expect(Services.invoke<string>("health.status")).resolves.toBe("ready");
    expect(calls).toEqual(["health.status"]);
  });
});
