// Private production-path probe, not an exported related-window factory.
import { bindRelatedDocumentLifetime } from "../../runtime/related-window-lifetime";
import { RELATED_DOCUMENT_SHELL_PATH } from "../../bootstrap/related-document";

const owner = globalThis as any;
owner.shared = { value: 41 };
const bridge = owner[Symbol.for("zapp.bridge")];
function require(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}

async function run() {
  require(window.open(RELATED_DOCUMENT_SHELL_PATH) === null, "unprepared popup");
  const failed = await bridge.invoke("prepareFailure", {}, { timeout: 0 });
  require(window.open(failed.address), "missing partial allocation");
  await bridge.invoke("rollback", {}, { timeout: 0 });

  const reservation = await bridge.invoke("prepare", {}, { timeout: 0 });
  const identity = { windowId: reservation.windowId, documentToken: reservation.documentToken };
  let childBridge: any;
  // The future factory must attach this internal observer BEFORE opening the
  // prepared child, not in the consumer's post-creation continuation.
  const lifetime = bindRelatedDocumentLifetime(identity, { _dispose: error => childBridge?._dispose(error) });
  let notifications = 0;
  const stopObserving = bridge._observeRelatedDocument(identity.windowId, identity.documentToken, (reason: string) => {
    notifications++;
    lifetime.invalidate(identity, reason);
  });
  let early = 0;
  const invalidated = new Promise<void>(resolve => lifetime.subscribe(() => { early++; resolve(); }));
  const completion = bridge.invoke("completion", {}, { timeout: 0 });
  const stopped = location.search.includes("stopped=1");
  const immediate = location.search.includes("immediate=1");
  if (stopped) await bridge.invoke("stopManager", {}, { timeout: 0 });
  const child = window.open(reservation.address);
  require(child, "missing child");
  const completed = await completion;
  if (stopped) {
    require(completed === false, "stopped manager published child");
    stopObserving();
    bridge.post(JSON.stringify({ t: 3, m: "pass" }));
    return;
  }
  require(completed === true, "child adoption failed");
  if (!immediate) {
    require(child.document.head && child.document.body && !child.document.scripts.length
      && !child.document.body.children.length, "shell not empty/ready");
    require(child.opener.shared === owner.shared && child.document !== document, "wrong document family");
    childBridge = (child as any)[Symbol.for("zapp.bridge")];
    require(await childBridge.invoke("echo", {}, { timeout: 0 }) === 42, "wrong child bridge");
    if (location.search.includes("family=1")) {
      require(await bridge.invoke("familyVeto", {}, { timeout: 0 }) === false, "family veto failed");
      require(!child.closed && !window.closed && notifications === 0, "veto destroyed family");
      bridge.post(JSON.stringify({ t: 3, m: "familyAccept" }));
      return;
    }
    const held = childBridge.invoke("hold", {}, { timeout: 0 }).catch((error: unknown) => error);
    // The owner round trip proves native received the child's held request.
    require(await bridge.invoke("held", {}, { timeout: 0 }) === true, "held request not registered");
    child.close();
    await invalidated;
    const failure = await held;
    require(failure.code === "RELATED_WINDOW_INVALIDATED" && failure.windowId === identity.windowId,
      "retained child promise did not reject with its document identity");
    require(await bridge.invoke("alive", {}, { timeout: 0 }) === 43, "owner work was retired");
    const again = await childBridge.invoke("hold", {}, { timeout: 0 }).catch((error: unknown) => error);
    require(again === failure, "retired transport accepted more work or changed its error");
  } else {
    // Native closes immediately after adoption, before publishing completion.
    // The registration above still receives the terminal event.
    await invalidated;
  }
  require(notifications === 1 && early === 1, "terminal delivery was lost or duplicated");
  let late = 0;
  lifetime.subscribe(() => { late++; });
  require(late === 0, "late subscription ran inline");
  await Promise.resolve();
  require(Number(late) === 1, "late subscriber missed remembered invalidation");
  require(!bridge._onRelatedDocumentInvalidated(reservation.ownerToken, identity.windowId,
    identity.documentToken, "duplicate"), "duplicate notification was delivered");
  stopObserving(); stopObserving();
  bridge.post(JSON.stringify({ t: 3, m: "pass" }));
}

void run().catch(error => {
  console.error(error);
  bridge.post(JSON.stringify({ t: 3, m: "fail" }));
});
