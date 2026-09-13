import React, { useState } from "react";
import { createRoot } from "react-dom/client";
import { createPortal, flushSync } from "react-dom";

// Attaches handlers defined in the surviving owner's realm to a promise
// created in the child. No caller-side transport or promise proxy is used.
function observe(promise) {
  const state = { settled: false, count: 0, value: undefined, error: undefined };
  promise.then(
    value => { state.count++; state.settled = true; state.value = value; },
    error => { state.count++; state.settled = true; state.error = error; },
  );
  return state;
}

export async function runLifecycle(owner, { openChild, until, assert, sleep, assertions }) {
  const first = await openChild();
  const second = await openChild();
  const a = first.__directBridge;
  const b = second.__directBridge;
  const observed = async marker => (await owner.invoke("stats")).observations.some(item => item.marker === marker);
  assert("owner tracks two document endpoints", owner.trackedChildren === 2);
  let target;
  function App() {
    const [document, setDocument] = useState(null);
    target = setDocument;
    return <section>{document && createPortal(<p id="lifecycle-portal">Alive</p>, document.body)}</section>;
  }
  const root = createRoot(document.querySelector("#root"));
  flushSync(() => root.render(<App />));
  flushSync(() => target(first.document));
  let cleanupCount = 0;
  a.onDispose(() => {
    cleanupCount++;
    flushSync(() => target(null));
  });

  // A cancelled native child close preserves the document, pending operation,
  // portal and cleanup subscription. Cancellation is non-destructive.
  await owner.invoke("veto-close", { target: a.identity, veto: true });
  const preservedToken = a.token;
  const preserved = observe(a.invoke("delayed", { marker: "cancelled-child-close" }));
  await until("vetoed request entered native", () => observed("cancelled-child-close"));
  await owner.invoke("close-child", { target: a.identity });
  let stats = await owner.invoke("stats");
  assert("cancelled child close preserves native registration", stats.cancelledCloses === 1 && stats.closedChildren === 0 && stats.dropped === 0);
  assert("cancelled child close does not invalidate frontend", a.isReady && a.token === preservedToken && cleanupCount === 0);
  assert("portal survives close cancellation", first.document.querySelector("#lifecycle-portal") !== null);
  await until("pending request survives cancellation", () => preserved.settled);
  assert("cancelled-close request resolves normally", preserved.count === 1 && !preserved.error && preserved.value.sender === a.identity);
  await owner.invoke("veto-close", { target: a.identity, veto: false });

  // Force the native lifecycle notification path, independent of whether this
  // WebKit build happens to run pagehide when an NSWindow closes.
  a.suppressPagehideForTest(true);
  owner.holdInvalidationsForTest(true);
  const retainedPromise = a.invoke("delayed", { marker: "retained-after-native-close" });
  const retained = observe(retainedPromise);
  const siblingObserver = b.observeForTest(retainedPromise);
  await until("retained request entered native", () => observed("retained-after-native-close"));
  await owner.invoke("close-child", { target: a.identity });
  await until("owner received held lifecycle notification", () => owner.heldInvalidations === 1);
  stats = await owner.invoke("stats");
  assert("native closure does not wait for JS cleanup", stats.closedChildren === 1 && stats.dropped === 1 && !retained.settled && cleanupCount === 0);
  owner.holdInvalidationsForTest(false);
  await until("owner-held child promise rejects", () => retained.settled);
  await until("sibling-held child promise rejects", () => siblingObserver.settled);
  assert("retained promise rejects exactly once", retained.count === 1 && retained.error?.code === "PROBE_DOCUMENT_INVALIDATED");
  assert("native close reason reaches retained promise", retained.error.reason === "native-close");
  assert("surviving sibling observes the same rejection", siblingObserver.count === 1 && siblingObserver.error === retained.error);
  assert("pending map drained and portal unmounted", a.pendingCount === 0 && cleanupCount === 1 && a.disposed);
  assert("closed document released from family registry", owner.trackedChildren === 1);
  const stale = observe(a.invoke("echo", { marker: "retired-endpoint" }));
  await until("retired endpoint rejects locally", () => stale.settled);
  assert("retired bridge cannot create new requests", stale.error?.code === "PROBE_DOCUMENT_INVALIDATED" && !(await observed("retired-endpoint")));
  a.dispose("duplicate");
  assert("duplicate disposal cannot rerun cleanup", cleanupCount === 1 && retained.count === 1);
  assert("surviving sibling still reaches native", (await b.invoke("echo")).sender === b.identity);

  // Exercise native invalidation for replacement with pagehide disabled too.
  b.suppressPagehideForTest(true);
  const previousToken = b.token;
  const replaced = observe(b.invoke("delayed", { marker: "retained-after-reload" }));
  await until("replacement request entered native", () => observed("retained-after-reload"));
  second.location.href = new URL("direct-child.html?lifecycle=replaced", location.href).href;
  await until("new child document activated", () => second.__directBridge?.isReady && second.__directBridge.token !== previousToken);
  await until("owner-held replaced promise rejects", () => replaced.settled);
  const fresh = second.__directBridge;
  assert("replacement rejects old promise once", replaced.count === 1 && replaced.error?.code === "PROBE_DOCUMENT_INVALIDATED");
  assert("replacement reason is document-specific", replaced.error.reason === "document-replaced");
  assert("old registry entry replaced without accumulation", owner.trackedChildren === 1 && b.disposed && fresh.isReady);
  owner.invalidateChild({ windowId: fresh.identity, token: previousToken, reason: "late-old-event" });
  assert("late old-document invalidation cannot dispose replacement", fresh.isReady && (await fresh.invoke("echo")).sender === fresh.identity);

  let callbacks = 0;
  const remove = fresh.onDispose(() => { callbacks += 100; });
  remove();
  fresh.onDispose(() => { throw new Error("deliberately failing fixture cleanup"); });
  fresh.onDispose(() => { callbacks++; });
  const closedThroughDOM = observe(fresh.invoke("delayed", { marker: "dom-close" }));
  await until("DOM close request entered native", () => observed("dom-close"));
  second.close();
  await until("DOM close invalidates retained promise", () => closedThroughDOM.settled);
  await until("both native children closed", async () => (await owner.invoke("stats")).closedChildren === 2);
  assert("ordinary DOM close also rejects retained promise", closedThroughDOM.error?.code === "PROBE_DOCUMENT_INVALIDATED");
  assert("cleanup errors and unsubscription cannot strand other cleanup", callbacks === 1 && fresh.cleanupErrors === 1);
  assert("family registry drained", owner.trackedChildren === 0);
  await sleep(400); // all previously scheduled native callbacks have had time to run
  assert("late callbacks cannot resettle rejected promises", retained.count === 1 && siblingObserver.count === 1 && replaced.count === 1 && closedThroughDOM.count === 1);
  flushSync(() => root.unmount());
  void owner.invoke("finish", { pass: true, assertions });
}
