import React, { createContext, useContext, useState } from "react";
import { createRoot } from "react-dom/client";
import { createPortal, flushSync } from "react-dom";

const Context = createContext(null);
const shared = { identity: "same-object", origin: location.origin };
const assertions = [];
let child = null;
let setTarget;
let getCount;
let callback;

const send = value => window.webkit.messageHandlers.probe.postMessage(value);
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
function assert(name, condition) {
  assertions.push({ name, pass: Boolean(condition) });
  if (!condition) throw new Error(name);
}
async function until(name, predicate) {
  const deadline = performance.now() + 3000;
  while (performance.now() < deadline) {
    if (predicate()) return;
    await sleep(20);
  }
  throw new Error(`timeout: ${name}`);
}

function Inspector({ count, increment }) {
  const model = useContext(Context);
  return <section>
    <h2>Child native window</h2>
    <p>This UI belongs to the parent's React tree.</p>
    <p id="child-count">{count}</p>
    <p id="context">{model === shared ? "shared-context-identity" : "wrong-context"}</p>
    <button id="increment" onClick={increment}>Increment shared state</button>
  </section>;
}
function App() {
  const [count, setCount] = useState(0);
  const [target, updateTarget] = useState(null);
  setTarget = updateTarget;
  getCount = () => count;
  callback = () => setCount(value => value + 1);
  return <Context.Provider value={shared}>
    <h2>Owner native window</h2>
    <p>One React root, two documents.</p>
    <p id="parent-count">{count}</p>
    <p>{location.protocol} / {new URLSearchParams(location.search).get("child")}</p>
    {target && createPortal(<Inspector count={count} increment={callback} />, target)}
  </Context.Provider>;
}

function openChild() {
  const mode = new URLSearchParams(location.search).get("child");
  const address = mode === "url" ? new URL("child.html", location.href).href : "about:blank";
  child = window.open(address, "_blank", "width=510,height=350");
  assert("window.open returns a child WindowProxy", child !== null);
}
async function mountChild() {
  const mode = new URLSearchParams(location.search).get("child");
  await until("child document ready", () => child.document.body &&
    (mode !== "url" || child.childDocumentReady));
  assert("opener relationship preserved", child.opener === window);
  assert("child has a separate DOM document", child.document !== document);
  assert("child has separate realm intrinsics", child.Array !== Array);
  child.sharedModel = shared;
  child.parentCallback = callback;
  assert("ordinary object identity crosses related realms", child.sharedModel === shared);
  assert("function identity crosses related realms", child.parentCallback === callback);
  child.document.head.appendChild(child.document.importNode(document.querySelector("style"), true));
  flushSync(() => setTarget(child.document.body));
  assert("portal renders into child document", child.document.querySelector("#increment") !== null);
  assert("React context keeps same object identity", child.document.querySelector("#context").textContent === "shared-context-identity");
}
async function clickAndCheck(expected, label) {
  child.document.querySelector("#increment").click();
  await until(label, () => getCount() === expected &&
    child.document.querySelector("#child-count").textContent === String(expected) &&
    document.querySelector("#parent-count").textContent === String(expected));
  assert(label, true);
}
async function run() {
  const options = new URLSearchParams(location.search);
  if (options.get("child") === "cross-origin") {
    const address = new URL("child.html", location.href);
    address.hostname = location.protocol === "zapp:" ? "other" : "localhost";
    child = window.open(address.href, "_blank");
    assert("cross-origin child opens", child !== null);
    await until("cross-origin navigation commits", () => window.__lastChildNavigation === address.href);
    let blocked = false;
    try { void child.document.body; }
    catch (error) { blocked = error.name === "SecurityError"; }
    assert("cross-origin child DOM access rejected", blocked);
    child.close();
    await until("cross-origin child closes", () => child.closed);
    await sleep(150);
    send({ kind: "result", pass: true, url: location.href, assertions });
    return;
  }
  flushSync(() => createRoot(document.querySelector("#root")).render(<App />));
  openChild();
  await mountChild();
  await clickAndCheck(1, "child React event updates both windows");
  send({ kind: "hide-parent" });
  await sleep(250);
  await clickAndCheck(2, "hidden owner still drives child state");
  send({ kind: "show-parent" });
  flushSync(() => setTarget(null));
  child.close();
  await until("child closes", () => child.closed);
  assert("child close observable in owner", true);
  openChild();
  await mountChild();
  assert("owner state survives child recreation", child.document.querySelector("#child-count").textContent === "2");
  await clickAndCheck(3, "recreated child remains interactive");
  flushSync(() => setTarget(null));
  child.close();
  await until("second child closes", () => child.closed);
  await sleep(150);
  send({ kind: "result", pass: true, react: React.version, url: location.href, assertions });
}
window.addEventListener("error", event => send({ kind: "log", error: String(event.error || event.message) }));
run().catch(error => send({ kind: "result", pass: false, error: String(error), stack: error.stack, assertions }));
