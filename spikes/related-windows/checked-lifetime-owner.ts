// Fixture controls only; the transport and lifetime state are the real runtime.
import { bindRelatedDocumentLifetime, type RelatedDocumentLifetime } from "../../runtime/related-window-lifetime";

const globals = globalThis as any;
const report = (message: string) => globals.webkit.messageHandlers.checked.postMessage(message);
const assert = (value: unknown, message: string) => { if (!value) throw new Error(message); };
const fail = (error: unknown) => report(`FAIL: ${String(error)}`);
window.addEventListener("error", event => fail(event.error));
window.addEventListener("unhandledrejection", event => { event.preventDefault(); fail(event.reason); });

let child: any;
let childBridge: any;
let life: RelatedDocumentLifetime;
let pending: Promise<any>;
let cleanups = 0;
globals.__checkedTrack = (windowId: string, documentToken: string) => {
  assert(child && child.document.head && child.document.body, "shell not ready");
  assert(child.document !== document && child.Array !== Array, "expected distinct document/realm");
  assert(globals.denied === null, "second creation should be refused");
  const bridge = child[Symbol.for("zapp.bridge")];
  childBridge = bridge;
  assert(bridge && typeof bridge._dispose === "function", "production bridge unavailable");
  life = bindRelatedDocumentLifetime({ windowId, documentToken }, bridge, fail);
  life.subscribe(() => { cleanups++; });
  const request = bridge.invoke("checked-pending", {}, { timeout: 0 });
  assert(!(request instanceof Promise), "request was not created in child realm");
  pending = request.catch((error: unknown) => error);
  bridge.invoke("checked-ping", {}, { timeout: 1000 }).then((value: unknown) => {
    assert(value === 42, "direct child reply missing");
    child.close();
  }).catch(fail);
};

globals.__checkedInvalidated = (windowId: string, documentToken: string) => {
  assert(child.closed, "native document close must precede JS cleanup");
  assert(!life.invalidate({ windowId, documentToken: "stale" }, "stale"), "stale identity accepted");
  assert(life.invalidate({ windowId, documentToken }, "The child document closed."), "invalidation missing");
  assert(cleanups === 0, "cleanup ran inline");
  life.subscribe(() => { cleanups++; });
  pending.then(async error => {
    assert(error.code === "RELATED_WINDOW_INVALIDATED" && error.windowId === windowId, "wrong retained rejection");
    const late = await childBridge.invoke("checked-ping", {}, { timeout: 0 }).catch((failure: unknown) => failure);
    assert(late === error, "retired transport accepted new work");
    assert(cleanups === 2, "early/late subscriptions did not each run once");
    assert(!life.invalidate({ windowId, documentToken }, "duplicate"), "duplicate invalidation accepted");
    report("pass");
  }).catch(fail);
};

child = window.open("/child.html");
globals.denied = window.open("/child.html");
assert(child, "child creation failed");
