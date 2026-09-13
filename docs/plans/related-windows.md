# Related windows

Status: **approved contract, implementation in progress**, 2026-09-13.

The runtime now provides the event/error/type declarations, a tested internal
document-lifetime helper, and terminal disposal of the production WebView bridge.
A checked-Z WebKit probe connects those pieces across actual child closure.
**`createRelatedWindow` is not implemented or exported yet.** The example below
describes the intended API, not a runnable feature today.
The [platform research](../experiments/related-windows.md) records the evidence
and remaining native integration gates separately.

## One document, one handle

Independent windows remain the default. Related windows are an explicit option
for a frontend owner that renders into another native window's document while
retaining application state and ordinary object/function identity. They are not
a React-specific API or a lower-permission sandbox.

The approved factory name is `createRelatedWindow`; it returns a Promise of
`RelatedWindowHandle`, extending `WindowHandle` with a readonly `document` and
terminal invalidation subscription. `ChildWindow` remains available vocabulary
for future native parenting features; related documents do not imply all of
those semantics.

Intended usage after integration:

```ts
import { createRelatedWindow, RelatedWindowEvent } from "@zappdev/runtime/window";

const inspector = await createRelatedWindow({ title: "Inspector" });
const root = inspector.document.createElement("section");
inspector.document.body.append(root);

const cleanup = inspector.subscribe(RelatedWindowEvent.INVALIDATED, event => {
  // Unmount framework UI and release retained document references here.
  root.remove();
  console.log(event.windowId, event.reason);
});

inspector.focus();
// cleanup.unsubscribe() stops this callback only; it does not close the window.
```

The current document is the owner. Each related window has its own native window
identity and direct native bridge, without loading another copy of the frontend
application bundle. Its authority is inherited from the validated family; it
cannot request a stronger or nominally isolated weaker profile. The first tier
does not accept arbitrary child URLs, cross-document child navigation, or
capability-profile overrides.

An owner-defined callback rendered through a portal is still owner code and
uses the owner's imports/bridge. A child-defined function uses that child's
bridge, even when called by the owner. DOM placement does not change provenance.

## What creation promises

The factory resolves only when all of these hold:

1. The native window exists and its same-origin minimal document shell has a
   usable `head` and `body`.
2. The child's own bridge is ready, with native-validated inherited authority.
3. The exact document identity is registered for request routing, stale-reply
   rejection, and lifetime teardown.
4. The owner is still live and no accepted teardown has invalidated the child.

`DOMContentLoaded` alone is not this handshake. Readiness does not promise fonts,
application rendering, layout completion, or physical pixel presentation.
Partial failure must unwind the native window and registrations before rejecting;
permission and native creation failures continue to use the existing error model.

A handle stays tied to its original document. It never silently retargets after
replacement. Hiding or minimizing preserves that document. Accepted child close,
owner close, or owner replacement invalidates it. A cancelled family close
preserves the family before any destructive teardown begins.

## Invalidation and cleanup

Native routing must become terminal independently of frontend cleanup. The
framework rejects pending requests belonging to the retired child document and
requests cancellation of their native work; unrelated owner/sibling requests
continue. Cancellation is cooperative and cannot undo completed side effects.

Framework close requests run cancellation preflight. Intrinsic DOM
`window.close()` is already committed by the time WebKit reports it, so terminal
cleanup cannot turn it back into a cancellable request. Zapp does not replace or
intercept the DOM primitive.

`RelatedWindowEvent.INVALIDATED` is a remembered, queued, one-shot notification:

- Every subscription is independent, including repeated registration of the
  same function. Active callbacks are queued in registration order.
- A late subscription queues the remembered terminal event; it does not run
  inline during `subscribe`.
- `unsubscribe()` is idempotent and suppresses that subscription's queued
  delivery if it has not begun. It does not cancel invalidation or other cleanup.
- Exceptions in one callback do not prevent the others. Returned Promise
  rejections are observed, but cleanup is never awaited before native closure.
- Duplicate or stale document notifications do not trigger another delivery or
  affect a replacement document, even if a native window ID is reused.

This terminal notification is not a new cancellable event and does not change
ordinary window-event delivery. Native closure never waits for a JS
acknowledgement. Delivery requires a surviving, scheduled observer realm; a
blocked owner can delay JS cleanup and a destroyed owner cannot execute it.
Invalidation also cannot revoke raw DOM/object references already retained by
application code. Users and framework adapters must release those references.

## Errors

`RelatedWindowInvalidatedError` lives in `@zappdev/runtime/window` and carries:

- `code: "RELATED_WINDOW_INVALIDATED"` for stable classification;
- `windowId` identifying the affected related window;
- `reason`, a human-readable explanation, not an exhaustive reason enum.

A retained child-created Promise can reject when observed by an owner or sibling.
Do not rely solely on cross-realm `instanceof`: error constructors can belong to
different realms. The stable code remains available. Malformed bridge error
metadata falls back to the generic invocation error rather than inventing a
window identity or reason.

## Implementation and evidence

The internal `RelatedDocumentLifetime` helper belongs in the observing owner's
realm. It latches terminal state before retiring transport, guards reentrant
calls, snapshots document identity, and isolates callbacks. The transport supplies
its existing pending-request disposal operation: the helper adds no second
per-request map or Promise wrapper to ordinary service calls. Native provenance
validation and physical window teardown remain outside this helper.

- [x] Approve naming, readiness, same-trust authority, document-owned lifetime,
      and remembered invalidation/error contract.
- [x] Add public event/error/type declarations and internal lifetime helper.
- [x] Test queued/late delivery, independent unsubscribe, stale identities,
      reentrancy, cleanup failures, typed overloads, and cross-realm Promises.
- [x] Bind the helper to the actual bootstrap's pending-request disposal and
      prove retained child-Promise rejection after native closure in checked Z.
- [ ] Integrate the checked-Z family/document registry into the window manager;
      do not promote the Objective-C oracle into production.
- [ ] Implement the readiness handshake and partial-creation cleanup.
- [ ] Carry family close preflight, real Z task cancellation, origin/capability
      checks, renderer loss, and navigation gates through native integration.
- [ ] Expose the public factory and add a Z Notes demonstration.
- [ ] Re-run representative application benchmarks and other-platform probes.

Focused validation from the repository root:

```sh
bun test runtime/related-window-lifetime.test.ts runtime/related-window-types.test.ts runtime/window-api.test.ts runtime/window-errors.test.ts
bun test runtime/related-window-transport.test.ts
bun run check
```

The cross-realm unit test uses isolated JavaScript contexts; it does not prove
WebKit renderer scheduling or production cancellation. The separate bounded
[native probes](../../spikes/related-windows/README.md) establish narrower platform
facts. Their remaining gaps stay explicit until the corresponding integration
tests pass.

The [checked-Z lifetime probe](../../spikes/related-windows/checked-z/lifetime.zs)
uses the production bundled bootstrap and owner-side helper. Native and Stage 0
both pass at `-O0`/`-O2` with UBSan. It distinguishes bridge startup from document
readiness, validates the sending WebView/main frame/exact fixture URL, sends a
reply directly to the child, and closes the native child before notifying the
owner. A retained child Promise rejects there; early and late cleanup each run
once; a disposed bridge cannot submit another request.

This is an HTTP-only single-child integration proof with fixed native fixture
identity, not the production creation handshake or family registry. It does not
yet prove authority-catalog inheritance, owner replacement, renderer failure,
custom-protocol readiness, or cancellation of a real Z service task. The held
native request is an instrumented pending request, not a running service.
