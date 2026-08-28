import { describe, expect, it } from "bun:test";
import { bundleWebviewBootstrapRaw } from "../bootstrap/codegen";

const BRIDGE_KEY = Symbol.for("zapp.bridge");
const CONFIG_KEY = Symbol.for("zapp.bootstrapConfig");

type PostedMessage = {
  t: number;
  id?: number;
  m?: string;
};

describe("WebView service cancellation", () => {
  it("bridges AbortSignal cancellation without leaking completed requests", async () => {
    const messages: PostedMessage[] = [];
    const previousWindow = (globalThis as any).window;
    const previousBridge = (globalThis as any)[BRIDGE_KEY];
    const previousConfig = (globalThis as any)[CONFIG_KEY];

    (globalThis as any)[CONFIG_KEY] = { permissions: { platform: "ios" } };
    (globalThis as any).window = {
      addEventListener() {},
      webkit: {
        messageHandlers: {
          zapp: {
            postMessage(message: string) {
              messages.push(JSON.parse(message) as PostedMessage);
            },
          },
        },
      },
    };

    try {
      const source = await bundleWebviewBootstrapRaw();
      Function(source)();
      const bridge = (globalThis as any)[BRIDGE_KEY];
      messages.length = 0; // Ignore the bootstrap-ready message.

      const alreadyAborted = new AbortController();
      alreadyAborted.abort();
      const rejectedBeforeDispatch = bridge.invoke(
        "notes.create",
        {},
        { signal: alreadyAborted.signal },
      );
      await expect(rejectedBeforeDispatch).rejects.toMatchObject({ name: "AbortError" });
      expect(messages).toEqual([]);

      const active = new AbortController();
      const cancelled = bridge.invoke("notes.create", {}, {
        signal: active.signal,
        timeout: 1000,
      });
      const invoke = messages.at(-1);
      expect(invoke).toMatchObject({ t: 1, m: "notes.create" });
      active.abort();
      await expect(cancelled).rejects.toMatchObject({ name: "AbortError" });
      expect(messages.at(-1)).toEqual({ t: 7, id: invoke?.id });

      const completedController = new AbortController();
      const completed = bridge.invoke("notes.count", {}, {
        signal: completedController.signal,
        timeout: 1000,
      });
      const completedInvoke = messages.at(-1);
      bridge._onInvokeResult(completedInvoke.id, true, "42");
      expect(await completed).toBe(42);

      const denied = bridge.invoke("__window:create", {}, { timeout: 1000 });
      const deniedInvoke = messages.at(-1);
      bridge._onInvokeResult(deniedInvoke.id, false, JSON.stringify({
        code: "PERMISSION_DENIED",
        message: "window creation is disabled",
        permission: "window:create",
      }));
      await expect(denied).rejects.toMatchObject({
        name: "PermissionDeniedError",
        code: "PERMISSION_DENIED",
        message: "window creation is disabled",
        permission: "window:create",
      });

      const countBeforeLateAbort = messages.length;
      completedController.abort();
      expect(messages).toHaveLength(countBeforeLateAbort);
    } finally {
      if (previousWindow === undefined) delete (globalThis as any).window;
      else (globalThis as any).window = previousWindow;
      if (previousBridge === undefined) delete (globalThis as any)[BRIDGE_KEY];
      else (globalThis as any)[BRIDGE_KEY] = previousBridge;
      if (previousConfig === undefined) delete (globalThis as any)[CONFIG_KEY];
      else (globalThis as any)[CONFIG_KEY] = previousConfig;
    }
  });
});
