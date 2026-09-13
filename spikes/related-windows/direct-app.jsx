import React, { createContext, useContext, useState } from "react";
import { createRoot } from "react-dom/client";
import { createPortal, flushSync } from "react-dom";

const owner = globalThis.__directBridge;
const assertions = [];
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const assert = (name, condition) => {
  assertions.push({ name, pass: Boolean(condition) });
  if (!condition) throw new Error(name);
};
async function until(name, predicate) {
  const deadline = performance.now() + 4000;
  while (performance.now() < deadline) {
    if (await predicate()) return;
    await sleep(20);
  }
  throw new Error(`timeout: ${name}`);
}
const Context = createContext(null);
const model = { identity: "one frontend owner" };
let setTarget;
let clickResult;
function Inspector() {
  const value = useContext(Context);
  return <div><p id="shared">{value === model ? "shared" : "wrong"}</p>
    <button id="owner-callback" onClick={() => {
      clickResult = owner.invoke("echo", { marker: "portal-owner-callback" });
    }}>Owner-defined callback</button></div>;
}
function App() {
  const [target, updateTarget] = useState(null);
  setTarget = updateTarget;
  return <Context.Provider value={model}>
    <p>Direct bridge proof</p>{target && createPortal(<Inspector />, target)}
  </Context.Provider>;
}
async function openChild() {
  const child = window.open(new URL("direct-child.html", location.href).href, "_blank");
  assert("related child opens", child !== null);
  await until("child bridge activated", () => child.__directBridge?.isReady);
  return child;
}
async function hasObserved(marker) {
  return (await owner.invoke("stats")).observations.some(item => item.marker === marker);
}
async function run() {
  await owner.ready;
  const options = new URLSearchParams(location.search);
  if (options.get("phase") === "replaced") {
    const stats = await owner.invoke("stats");
    assertions.push(...stats.previousAssertions);
    assert("owner replacement closes both children", stats.closedChildren === 2);
    assert("owner replacement cancels both child requests", stats.dropped === 2);
    assert("replacement owner gets working bridge", (await owner.invoke("echo")).sender === owner.identity);
    void owner.invoke("finish", { pass: true, assertions });
    return;
  }
  const first = await openChild();
  const second = await openChild();
  const a = first.__directBridge;
  const b = second.__directBridge;
  assert("three independent native identities", new Set([owner.identity, a.identity, b.identity]).size === 3);
  assert("separate bridge objects", owner !== a && a !== b);
  assert("related opener preserved with separate controllers", first.opener === window && second.opener === window);
  assert("separate documents and realm intrinsics", first.document !== document && first.Array !== Array);
  first.model = model;
  assert("shared object identity preserved", first.model === model);

  // All three local counters begin at 1. Replies must never land in another
  // window's map, even with identical request IDs and payload-spoofed identities.
  const replies = await Promise.all([owner, a, b].map((bridge, index) => bridge.invoke("echo", { marker: `initial-${index}` })));
  assert("overlapping request IDs", replies.every(reply => reply.id === 1));
  assert("native sender cannot be spoofed", replies.every((reply, index) => reply.sender === [owner, a, b][index].identity));
  assert("concurrent replies reach matching promises", replies.every((reply, index) => reply.marker === `initial-${index}`));
  assert("requests are settled in every endpoint", [owner, a, b].every(bridge => bridge.pendingCount === 0));

  // Disable the owner's public transport. Calling a child-defined function
  // cross-realm must still go straight to the child's native endpoint.
  const invokeOwner = owner.invoke;
  owner.invoke = () => { throw new Error("unexpected owner relay"); };
  const directPromise = a.invoke("echo", { marker: "no-owner-relay" });
  assert("promise created in child realm", directPromise instanceof first.Promise && !(directPromise instanceof Promise));
  const direct = await directPromise;
  owner.invoke = invokeOwner;
  assert("child works without owner transport", direct.sender === a.identity);

  flushSync(() => createRoot(document.querySelector("#root")).render(<App />));
  flushSync(() => setTarget(first.document.querySelector("#root")));
  assert("portal context remains shared", first.document.querySelector("#shared").textContent === "shared");
  first.document.querySelector("#owner-callback").click();
  assert("portal callback keeps owner caller identity", (await clickResult).sender === owner.identity);
  flushSync(() => setTarget(null));

  const scenario = options.get("scenario");
  if (scenario === "owner-close" || scenario === "owner-reload") {
    void a.invoke("delayed", { marker: "owner-close-a" });
    void b.invoke("delayed", { marker: "owner-close-b" });
    await until("both native requests pending", async () =>
      await hasObserved("owner-close-a") && await hasObserved("owner-close-b"));
    // Native output supplies the oracle after the owning JS document is gone.
    void owner.invoke(scenario === "owner-close" ? "close-owner" : "reload-owner", { assertions });
    return;
  }

  const frame = document.createElement("iframe");
  frame.src = new URL("direct-child.html?negative=1", location.href).href;
  document.body.appendChild(frame);
  await until("native subframe rejection", async () => (await owner.invoke("stats")).deniedFrames === 1);
  assert("same-origin raw subframe call rejected", true);
  frame.remove();

  const remoteURL = new URL("direct-child.html?negative=1", location.href);
  remoteURL.hostname = location.protocol === "zapp:" ? "other" : "localhost";
  const remote = window.open(remoteURL.href, "_blank");
  await until("native cross-origin rejection", async () => (await owner.invoke("stats")).deniedOrigins === 1);
  let blocked = false;
  try { void remote.document.body; } catch (error) { blocked = error.name === "SecurityError"; }
  assert("cross-origin DOM access still rejected", blocked);
  remote.close();
  await until("remote native window closes", async () => (await owner.invoke("stats")).closedChildren === 1);

  // Navigation reuses a native window but replaces its document. An old async
  // reply must not fulfill a new request whose counter has restarted at 1.
  void a.invoke("delayed", { marker: "old-document" });
  await until("old-document request entered native", () => hasObserved("old-document"));
  const oldToken = a.token;
  first.location.href = new URL("direct-child.html?replacement=1", location.href).href;
  await until("replacement activated", () => first.__directBridge?.isReady && first.__directBridge.token !== oldToken);
  const fresh = first.__directBridge;
  const freshPromise = fresh.invoke("echo", { marker: "new-document" });
  // Cover an old reply that was already queued for evaluateJavaScript before
  // native navigation invalidation, and therefore reaches the new document.
  fresh.accept({ id: 1, token: oldToken, windowId: fresh.identity, value: { marker: "stale-reply" } });
  assert("stale reply cannot settle a reused request ID", fresh.pendingCount === 1);
  const freshReply = await freshPromise;
  assert("navigation keeps window identity", fresh.identity === a.identity);
  assert("replacement has a new reply domain", fresh.token !== oldToken && freshReply.id === 1);
  await sleep(400);
  let stats = await owner.invoke("stats");
  assert("old document native request cancelled", stats.dropped === 1);
  assert("replacement reply not confused with old reply", freshReply.marker === "new-document" && fresh.pendingCount === 0);
  first.webkit.messageHandlers.directProbe.postMessage({
    id: 99, token: oldToken, method: "echo", args: { marker: "stale-request" },
  });
  await until("native rejects stale document token", async () => (await owner.invoke("stats")).deniedTokens === 1);
  assert("old document cannot invoke as the replacement", !(await hasObserved("stale-request")));

  void b.invoke("delayed", { marker: "closed-child" });
  await until("closing child request entered native", () => hasObserved("closed-child"));
  await owner.invoke("close-child", { target: b.identity });
  await sleep(400);
  stats = await owner.invoke("stats");
  assert("native close invalidates pending request", stats.dropped === 2 && stats.closedChildren === 2);
  assert("owner endpoint survives child unregister", (await owner.invoke("echo")).sender === owner.identity);
  assert("sibling endpoint survives child unregister", (await fresh.invoke("echo")).sender === fresh.identity);
  first.close();
  await until("all children natively closed", async () => (await owner.invoke("stats")).closedChildren === 3);
  void owner.invoke("finish", { pass: true, assertions });
}
run().catch(error => {
  console.error(error);
  void owner.invoke("finish", { pass: false, error: String(error), assertions });
});
