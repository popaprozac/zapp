# Related windows

Status: **approved contract, implementation in progress**, 2026-09-13.

The runtime now provides the event/error/type declarations, a tested internal
document-lifetime helper, and terminal disposal of the production WebView bridge.
A checked-Z WebKit probe connects those pieces across actual child closure.
The internal Z document registry proves inherited authority, subtree retirement,
and cancellation of real tasks on both compiler paths. Production macOS request
routing now uses document-bound identities, with a private bridge handshake and
stale-reply rejection across committed navigation.
**`createRelatedWindow` is not implemented or exported yet.** The example below
describes the intended API, not a runnable feature today.
The [platform research](../experiments/related-windows.md) records the evidence
and remaining native integration gates separately.

## Surfaces of an application, not necessarily more application instances

Choose where state belongs independently of how many native windows present it.
An inspector should not inherently require a second application bootstrap,
state store, or database connection. Related windows let one frontend owner
drive several documents, while the other models remain useful alongside it:

| Model | Where shared state lives | How windows coordinate |
|---|---|---|
| Independent frontends | Each window, with explicit synchronization | Messages |
| Zapp worker | A DOM-independent JS runtime | Calls/messages to a shared owner |
| Related-window family | One frontend owner driving several documents | Shared objects, callbacks, and framework reactivity |
| Native Z services | Backend-owned state and resources | Generated service calls and events |

These are complementary choices, not progressively better tiers. A worker could
own a remote connection, cached records, and background indexing; the frontend
owner could hold selection and editing state; related inspectors could display
that state; native services could provide persistence and OS integration. One
worker update enters the frontend state without separately synchronizing every
related document. A smaller application may keep its connection and state in the
frontend owner without a worker at all.

Related native windows share trust, scheduling, and document lifetime. They are
not independent frontend applications, and heavy work still belongs outside the
UI owner. Each child still costs a document, DOM, layout, and rendering work.

The startup benefit is avoiding duplicate loading/execution and initialization,
not necessarily removing duplicated bytes from the binary: packaged assets can
already be stored once. The current benchmark supports quicker warm child
startup, but neither measures true first paint nor isolates framework reuse as
the principal cause. See the [benchmark limits](../../spikes/related-windows/BENCHMARKS.md).

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
- [x] Implement the internal Z registry with native-minted document identities,
      unchanged inherited capabilities, generation-safe request tracking, and
      real-task cancellation tests for retired descendants and live siblings.
- [x] Split native window ownership/delivery out of the application runtime and
      bind production message handlers to their exact WebView/controller.
- [x] Integrate native document identities into ordinary window routing, request
      scheduling, completion consumption, and committed-navigation retirement.
- [x] Bind the production bridge to a native-offered token and reject stale
      replies in the actual JS execution realm, including reused request IDs.
- [x] Prove the internal child endpoint's inherited authority and two-stage
      shell/bridge readiness in headless tests and an actual WebKit-created child.
- [ ] Integrate related-child creation, shell/bridge readiness, inherited
      authority, and partial-creation cleanup into the window manager.
- [ ] Carry family close preflight, real Z task cancellation, origin/capability
      checks, renderer loss, and navigation gates through native integration.
- [ ] Expose the public factory and add a Z Notes demonstration.
- [ ] Re-run representative application benchmarks and other-platform probes.

Focused validation from the repository root:

```sh
bun test runtime/related-window-lifetime.test.ts runtime/related-window-types.test.ts runtime/window-api.test.ts runtime/window-errors.test.ts
bun test runtime/related-window-transport.test.ts
bun test runtime/document-transport.test.ts
bun run spikes/related-windows/document-routing.ts
bun run spikes/related-windows/document-routing.ts --related
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

### Native registry checkpoint

`native/z/framework/related-documents.zs` is framework-internal Z code, now
connected to macOS window routing but not the public factory. It owns one record
per live native window/document pair. Native-minted monotonically increasing
tokens prevent a retired identity from addressing a replacement document.
Private registry storage cannot be reset through the calling API.

An ordinary owner registers an already-validated `CapabilitySelection`. Related
creation accepts only its exact owner identity and new native window ID: there
is no profile override to accidentally grant different family authority.
Children remain unroutable until both native-validated bridge and shell readiness
have been observed. Retiring an owner also removes children still being prepared.

Each document owns an existing `PendingRequests` table. Internal request tickets
pair document identity with request ID and generation. Completion is consumed
once; stale completion and delayed attachment cannot affect a reused request ID
or a replacement document. Late attachments request cancellation immediately.
Committed subtree retirement first removes every affected record, then requests
cancellation, leaving unrelated owner/sibling documents active. The platform must
perform family cancellation preflight before committing retirement. Production
response delivery validates the identity before evaluating JavaScript, then the
bootstrap checks its token again when that script actually executes.

`bun run spikes/related-windows/registry.ts` runs the headless registry test with
native and Stage 0 emission at `-O0`/`-O2`, strict Clang warnings, UBSan, and a
10-second process-group runtime deadline. It verifies real tasks reach suspension
before child retirement, cancelled tasks do not continue afterward, and owner and
sibling tasks complete. No additional JS pending table or per-request Promise
wrapper is introduced. Registry lookups use hashed maps; subtree collection walks
the live ancestry at teardown, not on every bridge request. These are structural
cost observations, not new benchmark measurements.

The macOS ownership split has now landed: `application-runtime.zs` owns
application/services/workers, while `window-registry.zs` owns live and retired
native windows, document endpoints, delivery, and presentation operations.
Both are below 400 lines; the existing fewer-than-700-lines test remains strict
and passes again. One main-executor registry is allocated per application, not
per request; it owns the application name without keeping a duplicate String.
The native bridge now checks the exact WebView and content-controller identity
before checking main-frame/origin and decoding the body. Those references remain
under the existing registration's removal lifetime.

The bounded Z Notes packaged smoke passes after the move, including real bridge
replies, cancellation, origin/subframe rejection, and shutdown. This validates
the existing independent-window path, not the new related-document factory.

### Production document-routing checkpoint

Each native window owns a `BridgeDocument`. The message handler validates the
exact WebView/content controller, main frame, and configured origin before the
private handshake or any request reaches that endpoint. After committed
navigation, native code offers a new monotonic token to the current JS realm;
the bootstrap acknowledges it before releasing queued startup calls. The realm
nonce targets that handshake, not permissions. Neither token nor JSON chooses a
capability profile: routing uses the native identity's validated selection.

Requests acquire a document/request/generation ticket before scheduling. Task
controls attach to that exact ticket; a late attachment cancels itself. A reply
must consume its tracked completion and pass native document readiness checks.
It also carries the document token into `_onDocumentInvokeResult`, so an already
queued evaluation cannot resolve a replacement realm's reused request ID.
Native completion callbacks check the endpoint again before acting on errors.

Committed navigation, observed renderer termination, and accepted native close
retire the endpoint and request cancellation of its pending work. Provisional or
cancelled navigation does not retire the current document. The root handshake
establishes ordinary bridge routing; it is **not** the related-child factory's
stronger usable-`head`/`body` readiness promise.

The real-WebKit [document-routing probe](../../spikes/related-windows/document-routing.ts)
uses the production endpoint, transport, and bootstrap. Native/Stage 0 emission
both pass at `-O0`/`-O2` with UBSan. It commits two documents in one WebView, reuses
request ID `1`, rejects the old native ticket, deliberately evaluates an old
token reply of `99` in the new realm, and observes the correct new reply of `42`.
The fixture validates its own exact loopback URLs; the packaged Z Notes smoke
separately exercises production configured-origin and subframe rejection.

Costs are explicit: one endpoint/registry record and one handshake per document,
a small token prefix on requests, native parsing/copying, and a token check on
replies. The JS startup queue drains once; there is no additional steady-state
pending table or Promise wrapper. This is correctness evidence, not a new
throughput or zero-overhead measurement.

Remaining gates: related native creation and failed-creation unwind; full-family
close preflight; document-bound unsolicited event/menu/worker delivery; actual
renderer-crash and back/forward-cache integration; and complete owner/child
retirement behavior with real services. The headless cancellation test and the
WebKit replacement test prove different pieces, not the entire composition.

One upstream limitation remains recorded in Z's ownership-pressure log: native
lowering of stored async block closures is narrower than Stage 0. Routing keeps
its existing expression-bodied scheduling callback and named async entrypoint;
this checkpoint does not claim general closure/suspension parity.

### Internal related-child readiness checkpoint

`BridgeDocument.beginRelated` now reserves a child under an exact live, ready
owner. It accepts no capability override. The child keeps that reserved identity
through its first commit; later committed navigation is terminal rather than
silently retargeting a retained handle. Owner retirement also removes a child
that is still being prepared.

The child bootstrap queues calls until it has both a usable `head`/`body` and
native activation. Its acknowledgement establishes bridge presence; native code
then evaluates the matching realm/token and DOM, marks registry readiness, and
releases the queue. Wrong identities, retirement, cancellation, and timeouts
cannot start queued invocations. Native routing remains authoritative even if an
activation was queued before JavaScript disposal could run. Root windows retain
their existing handshake; they do not pay for the extra child DOM evaluation.

The [related-readiness probe](../../native/z/tests/related-readiness-native-smoke.zs)
uses WebKit's supplied child configuration, a fresh content controller and
retained Z protocol adapters. It refuses an unprepared child, accepts one with
the owner's exact authority, invokes from the child's head before body parsing,
receives a direct native reply, reads shared owner state, and closes the child
without retiring its owner. Native and Stage 0 pass at `-O0`/`-O2` with strict
warnings and UBSan; [raw results](../../spikes/related-windows/results/2026-09-13/related-readiness.json)
are retained. The echo is instrumentation, not a registered application service.

This proves the internal gate, not the public factory. Production manager
creation/failed-creation unwind, shell URL selection for packaged and Vite
content, family-wide close preflight, unsolicited delivery, and renderer loss
remain integration work. The HTTP child performs a real navigation; this does
not prove initial `about:blank` readiness, first paint, or a performance gain.

Two small compiler corrections landed with this checkpoint: Stage 0 preserves
the enclosing function's return type inside value-producing blocks, and native
emission declares Objective-C block adapters before nested callable bodies.
Nested block capture of an outer callback parameter remains a separate native
lowering gap. Whole-aggregate `replace` of ARC-bearing `Option` storage also
remains restricted; the fixture retains a direct endpoint before clearing its
one-shot reservation. Neither restriction is hidden by a native shim.
