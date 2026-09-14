// Private creation-authority probe. No exported factory or styling behavior.
import { bindRelatedDocumentLifetime } from "../../runtime/related-window-lifetime";

const bridgeKey = Symbol.for("zapp.bridge");
const root = window as any;
const bridge = root[bridgeKey];
function require(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}
function openFrom(owner: any, address: string): Window | null {
  // Define the operation in the selected document's realm; portal placement or
  // a parent-authored callback does not change an operation's provenance.
  return owner.eval("(address) => window.open(address)")(address);
}
async function finish(owner: any, prepared: any) {
  const ownerBridge = owner[bridgeKey];
  const identity = { windowId: prepared.windowId, documentToken: prepared.documentToken };
  let childBridge: any;
  const lifetime = bindRelatedDocumentLifetime(identity, { _dispose: error => childBridge?._dispose(error) });
  const stopped = ownerBridge._observeRelatedDocument(identity.windowId, identity.documentToken,
    (reason: string) => lifetime.invalidate(identity, reason));
  const invalidated = new Promise<void>(resolve => lifetime.subscribe(() => resolve()));
  const completion = ownerBridge.invoke("completion", { child: prepared.nativeId }, { timeout: 0 });
  const child = openFrom(owner, prepared.address) as any;
  require(child, "prepared popup was denied");
  require(await completion === true, "child failed to activate");
  childBridge = child[bridgeKey];
  require(await childBridge.invoke("ping", {}, { timeout: 0 }) === 42, "child bridge did not reply directly");
  require(openFrom(owner, prepared.address) === null, "reservation replay accepted");
  return { child, bridge: childBridge, invalidated, stopped };
}
async function create(owner: any) {
  const prepared = await owner[bridgeKey].invoke("prepare", {}, { timeout: 0 });
  require(prepared !== false, "prepare denied");
  return finish(owner, prepared);
}
async function run() {
  const scenario = new URLSearchParams(location.search).keys().next().value;
  if (scenario === "denied") {
    require(await bridge.invoke("prepare", {}, { timeout: 0 }) === false, "missing permission accepted");
    require(openFrom(root, "/.zapp/related.html") === null, "unprepared popup accepted");
    bridge.post(JSON.stringify({ t: 3, m: "pass" }));
    return;
  }
  if (scenario === "subframe") {
    const frame = document.createElement("iframe");
    const loaded = new Promise<void>(resolve => { frame.onload = () => resolve(); });
    frame.src = "/frame.html";
    document.body.append(frame);
    await loaded;
    const subframe = frame.contentWindow as any;
    const prepared = await bridge.invoke("prepare", {}, { timeout: 0 });
    require(prepared !== false, "owner prepare denied");
    // Even knowing a valid main document token and prepared URL cannot turn
    // this frame's own native endpoint into the owner's endpoint.
    subframe.eval("(payload) => webkit.messageHandlers.zapp.postMessage(payload)")(
      `@${prepared.ownerToken}\n${JSON.stringify({ t: 3, m: "forbidden" })}`);
    require(openFrom(subframe, prepared.address) === null, "subframe consumed owner reservation");
    require(await bridge.invoke("ping", {}, { timeout: 0 }) === 42, "subframe attempt retired owner");
    frame.remove();
    const child = await finish(root, prepared);
    child.child.close();
    await child.invalidated;
    child.stopped();
    bridge.post(JSON.stringify({ t: 3, m: "pass" }));
    return;
  }
  const child = await create(root);
  const sibling = await create(root);
  require(openFrom(child.child, "/.zapp/related.html") === null, "unprepared nested popup accepted");
  require(await child.bridge.invoke("ping", {}, { timeout: 0 }) === 42, "popup denial retired child");
  const prepared = await child.bridge.invoke("prepare", {}, { timeout: 0 });
  require(prepared !== false, "nested owner prepare denied");
  require(openFrom(root, prepared.address) === null, "root stole nested owner's reservation");
  const grandchild = await finish(child.child, prepared);
  require(grandchild.child.opener === child.child && grandchild.child.document !== child.child.document,
    "incorrect grandchild document owner");
  require(await bridge.invoke("familyVeto", {}, { timeout: 0 }) === true, "grandchild veto did not preserve family");
  require(!child.child.closed && !grandchild.child.closed && !sibling.child.closed, "veto destroyed a document");
  require(await grandchild.bridge.invoke("ping", {}, { timeout: 0 }) === 42, "veto retired grandchild bridge");
  if (scenario === "nested-owner-close") {
    bridge.post(JSON.stringify({ t: 3, m: "closeOwner" }));
    return; // Native verifies the family; a closed owner cannot promise cleanup.
  }
  require(scenario === "nested-child-close", "unknown authority scenario");
  require(await bridge.invoke("closeBranch", {}, { timeout: 0 }) === true, "branch teardown failed");
  await child.invalidated;
  require(await sibling.bridge.invoke("ping", {}, { timeout: 0 }) === 42, "branch teardown retired sibling");
  require(await bridge.invoke("ping", {}, { timeout: 0 }) === 42, "branch teardown retired root");
  // The grandchild's observer realm was the closed child; do not await cleanup
  // in that realm. Native checks both descendant identities are retired.
  grandchild.stopped(); child.stopped();
  sibling.child.close();
  await sibling.invalidated;
  sibling.stopped();
  bridge.post(JSON.stringify({ t: 3, m: "pass" }));
}
void run().catch(error => {
  console.error(error);
  bridge.post(JSON.stringify({ t: 3, m: "fail" }));
});
