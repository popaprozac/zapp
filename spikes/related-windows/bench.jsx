import React, { useState } from "react";
import { createRoot } from "react-dom/client";
import { createPortal, flushSync } from "react-dom";

const scriptLoadInitMs = performance.now() - window.__scriptStart;
const options = new URLSearchParams(location.search);
const mode = options.get("mode");
const childRole = location.pathname.endsWith("bench-independent.html");
const rows = Array.from({ length: 128 }, (_, id) => id);
let updateState;
let targetState;
let child = null;
let sequence = 0;
let callId = 0;
const pending = new Map();
const send = body => window.webkit.messageHandlers.probe.postMessage(JSON.stringify(body));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const twoFrames = win => new Promise(resolve => win.requestAnimationFrame(() => win.requestAnimationFrame(resolve)));
const initial = { sequence: 0, selected: 0, title: "Document 0" };

function Inspector({ model }) {
  return <section><h2>Document inspector</h2><p id="sequence">{model.sequence}</p>
    <p>{model.title}</p><div className="rows">{rows.map(id =>
      <div key={id} className={id === model.selected ? "row selected" : "row"}>Property {id}</div>
    )}</div></section>;
}
function ChildApp() {
  const [model, setModel] = useState(initial);
  updateState = setModel;
  return <Inspector model={model} />;
}
function OwnerApp() {
  const [model, setModel] = useState(initial);
  const [target, setTarget] = useState(null);
  updateState = setModel;
  targetState = setTarget;
  return <main><h2>State owner: {mode}</h2><p id="owner-sequence">{model.sequence}</p>
    <p>Same 128-row child inspector in both variants.</p>
    {target && createPortal(<Inspector model={model} />, target)}</main>;
}
function fail(error) { send({ kind: "failure", error: String(error.stack || error) }); }
function assert(value, label) { if (!value) throw new Error(label); }
function receive(payload) {
  const resolve = pending.get(payload.id);
  if (!resolve) return;
  pending.delete(payload.id);
  resolve(payload);
}
window.__receive = receive;

if (childRole) {
  flushSync(() => createRoot(document.querySelector("#root")).render(<ChildApp />));
  window.__applyUpdate = async ({ id, model, frames }) => {
    try {
      const start = performance.now();
      flushSync(() => updateState(model));
      assert(document.querySelector("#sequence").textContent === String(model.sequence), "child commit mismatch");
      const commitMs = performance.now() - start;
      if (frames) await twoFrames(window);
      const payload = { id, sequence: model.sequence, commitMs };
      if (mode === "related-root") window.opener.__receive(payload);
      else send({ kind: "ack", payload });
    } catch (error) { fail(error); }
  };
  window.addEventListener("load", () => {
    const payload = { scriptLoadInitMs, frameworkLoadedHere: true, directOpener: window.opener !== null };
    if (mode === "related-root") window.opener.__childReady(payload);
    else send({ kind: "ready", payload });
  });
} else {
  async function open() {
    const start = performance.now();
    const ready = new Promise(resolve => { window.__childReady = resolve; });
    const address = new URL(mode === "related" ? "bench-related.html" : "bench-independent.html", location.href);
    address.search = `mode=${mode}`;
    if (mode !== "independent") {
      child = window.open(address.href, "_blank", "width=510,height=350");
      assert(child, "window.open blocked");
    } else send({ kind: "open-independent", url: address.href });
    const info = await ready;
    const readyMs = performance.now() - start;
    if (mode === "related") {
      assert(info.directOpener && !info.frameworkLoadedHere, "related child bootstrap mismatch");
      flushSync(() => { updateState(initial); targetState(child.document.querySelector("#root")); });
      assert(child.document.querySelectorAll(".row").length === 128, "portal rows missing");
      await twoFrames(child);
    } else {
      assert(info.frameworkLoadedHere && info.directOpener === (mode === "related-root"), "child context relationship mismatch");
      // Same initial state; independent document already mounted its own root.
      await publish(initial, true);
    }
    return { readyMs, twoFramesMs: performance.now() - start, ...info };
  }
  async function close() {
    if (mode === "related") flushSync(() => targetState(null));
    const closed = new Promise(resolve => { window.__closed = resolve; });
    send({ kind: "close-child" });
    await closed;
    child = null;
    await sleep(40);
  }
  async function publish(model, frames = false) {
    const start = performance.now();
    flushSync(() => updateState(model));
    assert(document.querySelector("#owner-sequence").textContent === String(model.sequence), "owner commit mismatch");
    if (mode === "related") {
      assert(child.document.querySelector("#sequence").textContent === String(model.sequence), "portal commit mismatch");
      const localCommitMs = performance.now() - start;
      if (frames) await twoFrames(child);
      return { elapsedMs: performance.now() - start, localCommitMs };
    }
    const id = ++callId;
    const result = new Promise(resolve => pending.set(id, resolve));
    if (mode === "related-root") child.__applyUpdate({ id, model, frames });
    else send({ kind: "relay", payload: { id, model, frames } });
    const ack = await result;
    assert(ack.sequence === model.sequence, "reply sequence mismatch");
    return { elapsedMs: performance.now() - start, localCommitMs: ack.commitMs };
  }
  async function sample(count, batch, frames) {
    const measured = [];
    let start = 0;
    for (let index = 0; index < count + 20; index++) {
      if (index === 20) start = performance.now();
      // Coalesce all 32 logical changes before publishing in the batched case.
      let model;
      for (let n = 0; n < batch; n++) {
        sequence++;
        model = { sequence, selected: sequence % 128, title: `Document ${sequence}` };
      }
      const result = await publish(model, frames);
      if (index >= 20) measured.push(result);
    }
    return { samples: measured, wallMs: performance.now() - start, count,
      meanCompletionMs: (performance.now() - start) / count, logicalChangesPerCommit: batch };
  }
  async function run() {
    flushSync(() => createRoot(document.querySelector("#root")).render(<OwnerApp />));
    await sleep(150);
    const startup = [];
    for (let i = 0; i < 4; i++) {
      startup.push(await open());
      if (i !== 3) await close();
    }
    const delta = await sample(1000, 1, false);
    const coalesced32 = await sample(300, 32, false);
    const frames = await sample(24, 1, true);
    await close();
    send({ kind: "result", pass: true, mode, origin: location.protocol,
      react: React.version, ownerScriptLoadInitMs: scriptLoadInitMs,
      startup, delta, coalesced32, frames, totalUpdates: sequence });
  }
  run().catch(fail);
}
window.addEventListener("error", event => fail(event.error || event.message));
