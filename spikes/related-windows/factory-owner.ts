import { createRelatedWindow, RelatedWindowEvent } from "../../runtime/window-api";

const bridge = (window as any)[Symbol.for("zapp.bridge")];
// Inspect exact native correlation for the adversarial abort probe, never guess
// a token (it may advance more than once during an initial navigation).
const preparedById = new Map<string, { nativeId: number; documentToken: string }>();
const invoke = bridge.invoke;
bridge.invoke = (method: string, args?: Record<string, unknown>, options?: any) => {
  const pending = invoke(method, args, options);
  if (method === "__window:prepare-related") void pending.then((value: any) => preparedById.set(value.windowId, value), () => {});
  return pending;
};
function require(value: unknown, message: string): asserts value { if (!value) throw new Error(message); }
async function run() {
  const scenario = new URLSearchParams(location.search).keys().next().value;
  if (scenario === "factory-churn" || scenario === "factory-animated-churn") {
    const animated = scenario === "factory-animated-churn";
    const samples: number[] = [];
    for (let batch = 0; batch < 4; batch++) {
      for (let index = 0; index < 4; index++) {
        const child = await createRelatedWindow({ title: "Open/close ownership probe" });
        const childBridge = (child.document.defaultView as any)[Symbol.for("zapp.bridge")];
        await childBridge.invoke("watchRuntime");
        const invalidated = new Promise<void>(resolve => child.subscribe(RelatedWindowEvent.INVALIDATED, () => resolve()));
        child.close();
        await invalidated;
      }
      // Native close processing and autoreleased objects can finish on a later
      // run-loop turn, especially under compiler/test load. This is a bounded
      // observation deadline, never a framework teardown delay or RSS heuristic.
      const until = Date.now() + 3_000;
      do {
        await new Promise(resolve => setTimeout(resolve, 50));
        if (animated || await bridge.invoke("countRuntime") === 0) break;
      } while (Date.now() < until);
      samples.push(await bridge.invoke(animated ? "sampleOwnedRuntime" : "sampleRuntime"));
    }
    require(samples.every(count => count === 0),
      `retained closed runtime/native graphs: ${samples.join(",")}`);
  } else if (scenario === "factory-denied") {
    let denied = false;
    try { await createRelatedWindow(); } catch (error: any) { denied = error.code === "PERMISSION_DENIED"; }
    require(denied, "native capability denial was not surfaced");
  } else if (scenario === "factory-invalid") {
    const open = window.open;
    const observe = bridge._observeRelatedDocument;
    let opened: Window | null = null;
    window.open = (address) => { opened = open.call(window, address); return opened; };
    bridge._observeRelatedDocument = (id: string, token: string, invalidated: (reason: string) => void, created: () => void) =>
      observe(id, token, invalidated, () => { opened!.document.body.remove(); created(); });
    let rejected = false;
    try { await createRelatedWindow(); } catch (error: any) { rejected = error.code === "WINDOW_ERROR"; }
    finally { window.open = open; bridge._observeRelatedDocument = observe; }
    require(rejected, "invalid activated shell was published");
  } else if (scenario === "factory-rollback") {
    const open = window.open;
    window.open = () => null;
    let rejected = false;
    try { await createRelatedWindow(); } catch (error: any) { rejected = error.code === "WINDOW_ERROR"; }
    finally { window.open = open; }
    require(rejected, "blocked opening did not roll back");
  } else {
    const child = await createRelatedWindow({ title: "Public related inspector", width: 300, height: 220 });
    const retired = new Promise<void>(resolve => child.subscribe(RelatedWindowEvent.INVALIDATED, () => resolve()));
    const childRealm = child.document.defaultView as any;
    const childBridge = childRealm[Symbol.for("zapp.bridge")];
    require(childBridge !== bridge && await childBridge.invoke("ping") === 42, "child did not use its direct bridge");
    require(childRealm.opener === window, "incorrect owner document");
    const shared = { count: 0 };
    const button = child.document.createElement("button");
    button.onclick = () => shared.count++;
    child.document.body.append(button); button.click();
    require(shared.count === 1, "shared owner callback/object identity was lost");
    child.focus(); child.setTitle("Public inspector ready");
    if (scenario === "factory-veto") {
      await bridge.invoke("enableVeto");
      child.close(); await childBridge.invoke("ping");
      require(!childRealm.closed, "normal close bypassed veto");
      // Abort correlation is not authority to force-close a published handle.
      const correlation = preparedById.get(child.id);
      require(correlation, "missing exact native preparation correlation");
      await bridge.invoke("__window:abort-related", { nativeId: correlation.nativeId, documentToken: correlation.documentToken });
      require(!childRealm.closed && await childBridge.invoke("ping") === 42, "abort bypassed publication/close policy");
      await bridge.invoke("disableVeto");
    } else {
      const sibling = await createRelatedWindow({ title: "Sibling" });
      const siblingRetired = new Promise<void>(resolve => sibling.subscribe(RelatedWindowEvent.INVALIDATED, () => resolve()));
      child.close(); await retired;
      require(await (sibling.document.defaultView as any)[Symbol.for("zapp.bridge")].invoke("ping") === 42, "sibling retired with child");
      sibling.close(); await siblingRetired;
    }
    if (scenario === "factory-veto") { child.close(); await retired; }
    let invalid = false;
    try { child.focus(); } catch (error: any) { invalid = error.code === "RELATED_WINDOW_INVALIDATED"; }
    require(invalid, "stale related handle remained usable");
    await new Promise<void>(resolve => child.subscribe(RelatedWindowEvent.INVALIDATED, () => resolve()));
  }
  bridge.post(JSON.stringify({ t: 3, m: "pass" }));
}
void run().catch(error => { console.error(error); bridge.post(JSON.stringify({ t: 3, m: "fail", a: { error: String(error) } })); });
