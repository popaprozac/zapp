# Related windows

Status: **approved contract, implementation in progress**, 2026-09-13.

The runtime now provides the event/error/type declarations, a tested internal
document-lifetime helper, and terminal disposal of the production WebView bridge.
A checked-Z WebKit probe connects those pieces across actual child closure.
The internal Z document registry proves inherited authority, subtree retirement,
and cancellation of real tasks on both compiler paths. Production macOS request
routing now uses document-bound identities, with a private bridge handshake and
stale-reply rejection across committed navigation.
The private minimal shell is served by Vite and embedded by Z packaging, with
actual WebKit readiness verified through both delivery paths.
Production checked-Z allocation, one-shot completion/failure replies, and native
creation deadlines are now wired and exercised by a private WebKit harness.
Activated children are adopted into `app.windows` without another native
allocation, using the ordinary window controls and Z event lifecycle.
Family-wide close preflight now gives each affected window's synchronous Z
listener a veto before teardown or task cancellation. Accepted closure retires
the subtree; unrelated windows remain live.
Committed child retirement now sends a document-bound terminal notice to its
surviving owner, rejecting retained child requests through the existing bridge.
The real owner navigation delegate also passes replacement and injected
renderer-termination coverage; related reload/navigation and termination
retire the original child rather than retargeting its lifetime.
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

The current allocator selects no application injection profiles; it still
installs the framework bridge and document/window identity scripts. It does not
automatically inherit owner profiles or synchronize application CSS. Explicit
child injection and natural component styling are a separate
[unapproved design track](related-window-styling.md), not part of the implemented
behavior or an approved factory option. Close/lifetime integration remains next.

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
- [x] Deliver the same minimal child shell through Vite and the production
      embedded-asset handler, without loading another frontend entry or HMR client.
- [x] Wire the production native allocator/UI delegate, inherited endpoint,
      activation acknowledgement, deadline, and partial-creation rollback.
- [x] Adopt completed related children into the logical window manager and its
      existing controls/Z events, without allocating a second native window.
- [x] Carry family close preflight through the production native path and prove
      veto-preserved work versus accepted-close cancellation of real Z tasks.
- [x] Deliver unsolicited child terminal notices to the exact surviving owner
      document, including closure before the creation continuation resumes.
- [x] Exercise the production owner/child navigation delegates across owner
      replacement, child reload/refused navigation, and injected renderer-loss
      callbacks, including a family losing its original observer realm.
- [ ] Finish the creation-authority audit (including subframes and nested
      owners) before public factory integration; actual renderer-crash/recovery
      stress and broader platform coverage remain separate hardening work.
- [ ] Expose the public factory and add a Z Notes demonstration.
- [ ] Re-run representative application benchmarks and other-platform probes.

Focused validation from the repository root:

```sh
bun test runtime/related-window-lifetime.test.ts runtime/related-window-types.test.ts runtime/window-api.test.ts runtime/window-errors.test.ts
bun test runtime/related-window-transport.test.ts
bun test runtime/document-transport.test.ts
bun run spikes/related-windows/document-routing.ts
bun run spikes/related-windows/document-routing.ts --related
bun run spikes/related-windows/shell.ts
bun run spikes/related-windows/shell.ts --production
bun run spikes/related-windows/shell.ts --retirement
bun run spikes/related-windows/registry.ts --creations
bun native/z/testing/window-focus.ts
bun native/z/testing/window-focus.ts --native
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
Nested block capture of an outer callback parameter was subsequently fixed in
Z commit `bc27e0a7`, with stored callable ownership and native iteration parity
regressions. Whole-aggregate `replace` of ARC-bearing `Option` storage
remains restricted; the original fixture retained a direct endpoint before
clearing its optional storage. The creation guard below now stores plain
reservation identities separately from ARC endpoints; it does not require or
claim a general nested-ARC exchange operation.

### Vite and packaged shell checkpoint

The private `/.zapp/related.html` resource has one canonical HTML source. Vite
serves it before HTML transforms and SPA fallback; it contains no app entry,
script, bridge bundle, or HMR client. Production Z packaging embeds the same
bytes uncompressed in the existing process-lifetime asset catalog. A frontend
asset at that reserved path fails packaging instead of being silently replaced.
No new public configuration or URL option is introduced.

`bun run spikes/related-windows/shell.ts` runs the production asset generator,
Z scheme handler, document endpoint, and bridge against both a real Vite server
and `zapp://app`. All eight runs pass: native/Stage 0 × `-O0`/`-O2` ×
Vite/packaged, with strict Clang warnings, UBSan, and 15-second per-process
deadlines. Test-only injected JS invokes before body parsing, observes the
empty usable shell after activation, reads shared owner state, receives `42`
directly in the child, and closes it without retiring the owner. Unprepared
creation is refused. [Raw results](../../spikes/related-windows/results/2026-09-13/related-shell.json)
retain the exact outputs. The harness owns and closes its Vite server.

The shell itself grants no authority; creation still requires native owner and
document validation. These are real same-origin navigations, not an
`about:blank` shortcut or first-paint benchmark. Production manager creation and
failed-creation unwind, family close preflight, unsolicited event delivery, and
renderer/owner retirement remain the next integration gates before exposing
`createRelatedWindow`.

This broader asset-host test also exposed and fixed Stage 0's inferred-borrow
argument ABI for Objective-C protocol values: `helper(task)` now passes the
same object pointer as `helper(in task)`. Zapp's valid helper calls did not need
a workaround or new language syntax. The fix is Z commit `ad73dc7b`.

### Creation reservation and rollback checkpoint

`RelatedWindowCreations` is an internal main-executor guard owned by the macOS
window registry. It reserves a child only under the exact ready owner identity
with `window:create`, inherits that owner's selection without overrides, and
allows the matching native callback to claim the reservation once. A reservation
is correlation data, not proof of a trusted sender: callers still validate the
actual WebView, frame, and origin before claiming it.

The guard owns rollback until both readiness signals have completed and the
platform has retained the native runtime. Failure removes the reservation and
retires routing before invoking cleanup. Stale completion cannot affect a new
document with the same window ID. Late or duplicate resource attachment cleans
up the supplied resources instead of leaking them. Deadline checks, owner loss,
reentrant cleanup, fallback destruction, and terminal shutdown have deterministic
headless tests. Production native close prunes invalidated reservations, and
application shutdown cancels the table before closing native windows.

Run `bun run spikes/related-windows/registry.ts --creations` for the four-way
native/Stage 0 × `-O0`/`-O2` UBSan matrix. The real WebKit readiness and shell
fixtures now also force a failure after native view/window/registration
allocation. Before accepting a retry, they require revoked routing, closed
partial native state, and destruction of that registration's Z message handler.
The fresh child then receives `42` directly and closes normally. All four HTTP
and eight Vite/packaged cases pass. Evidence:
[headless](../../spikes/related-windows/results/2026-09-13/creations.json),
[HTTP](../../spikes/related-windows/results/2026-09-13/creation-rollback-http.json),
[Vite/packaged](../../spikes/related-windows/results/2026-09-13/creation-rollback-shell.json).

This revealed two Stage 0 compiler bugs, fixed in Z: immutable synthetic
`deinit` receivers rejected ordinary synchronous cleanup, and an owned capture
whose first body use passed a class argument emitted a duplicate retain.
Z commit `60230f39` fixes both with destructor-count regressions. The fixture does not wait for
arbitrary Objective-C autorelease draining to claim failed-registration cleanup.

At that checkpoint, scope remained deliberately narrow: the production registry **owned** this guard,
but the real allocation/claim proof is still in the checked-Z WebKit fixture.
Automatic platform deadline scheduling, prepare/claim/readiness wiring into the
production UI delegate, failure replies, family close preflight, and complete
document-bound event/retirement integration are still gates. The fixture injects
deterministic deadline ticks; it does not claim a production timeout timer.
`createRelatedWindow` remains unexported. No new public API or configuration was
introduced, and ordinary service calls do not touch the creation table.

### Production allocation and completion checkpoint

The macOS registry now owns `MacOSRelatedWindows`, installs its production
`WKUIDelegate`, and provides an internal, authenticated prepare entry. A pending
reservation binds one exact owner WebView/document to one private shell URL.
Unprepared popups remain refused. The allocator uses WebKit's supplied
configuration, installs a separate child message controller and registration,
retains its navigation/UI/window delegates, and returns the child WebView
without bootstrapping a second frontend application. All new host code is Z.

The child stays hidden until the shell exists and JavaScript successfully
acknowledges bridge activation. Registry routing readiness alone cannot resolve
creation. Completion removes the guard before the one-shot reply; failure
revokes routing and rolls back unpublished resources before rejection. Replies
target only the original ready owner identity, never a replacement document.
Presentation rechecks liveness after a potentially reentrant success callback.
A ten-second monotonic deadline uses one non-repeating native timer per pending
creation; completed creations stop it. Ordinary service calls use neither this
timer nor this table.

The production coordinator is split from native allocation and the reusable
navigation policy to keep the module graph acyclic. The registry can deliver a
document-bound response directly to a ready child; it does not relay through
the owner's JavaScript bridge.

`bun run spikes/related-windows/shell.ts --production` runs the actual child
allocator, delegates, message handler, and activation path. Its root prepare
route remains test instrumentation. Eight native/Stage 0 × `-O0`/`-O2` ×
Vite/packaged cases pass with strict Clang warnings, UBSan, empty stderr, and
bounded process groups. They refuse an unprepared popup, roll back a partial
allocation, reuse its numeric ID with a fresh identity, wait for activation,
read shared owner state, verify inherited grants, receive a direct child reply,
and close only the child. Evidence:
[production matrix](../../spikes/related-windows/results/2026-09-13/production-creations.json),
[activation/early-call matrix](../../spikes/related-windows/results/2026-09-13/activation-shell.json),
[headless completion matrix](../../spikes/related-windows/results/2026-09-13/creation-completion.json).
The headless matrix additionally verifies duplicate/late activation, cleanup
before failure replies, deadline expiry, and reply suppression after owner loss.
The real-time deadline is wired, but this matrix does not wait ten seconds to
claim timer-expiry evidence. The earlier registration-destruction fixture
remains distinct from this production allocator test.

The packaged Z Notes application smoke also passes after integration, including
normal services, worker activity, permission checks, and shutdown. Z commit
`3350fd12` closes the callback-assignment, receiver/constructor cleanup, and
optional header-provenance emission gaps encountered here; the framework does
not carry handwritten native replacements for those valid Z shapes.

At that checkpoint, the public `createRelatedWindow` factory remained unexported.
The next gates were logical adoption, family-wide cancellable close preflight,
document-bound unsolicited events, and broader renderer/owner retirement cases.
Nested related-owner creation is also not exposed by the registry's root-only
prepare entry. No new public API, permission, or configuration was added here.

### Logical window adoption checkpoint

An activated child now enters the existing `WindowManager` before its successful
creation reply. Internal adoption rejects inactive managers, empty identifiers,
and duplicate identifiers; it does not call the native allocator or publish
callbacks. The coordinator mints the related-window identifier, preserves the
document's validated capability selection, and does not change ordinary window
numbering. `app.windows.get()` and `all()` return the same logical identity.

The production allocator now returns the shared `MacOSWindowRuntime`, with the
ordinary close/focus/minimize/resize delegate and presentation observer. A
related configuration already retains its inherited scheme handler, so the
runtime's explicit handler owner is optional. Logical controls use the existing
platform lookup; there is no second related-only implementation of each control.

Retirement latches before external cleanup, revokes the document subtree before
user closed listeners, and removes the logical record exactly once. Reentrant
native cleanup cannot recursively retire it. Completed AppKit graphs remain
retained until the application run loop unwinds, matching ordinary windows;
failed unpublished creations are rolled back before rejection. If the manager
stops while a child loads, activation rejects instead of publishing an unusable
window. Stale handles cannot resurrect native controls.

Validation at this checkpoint:

- 24 headless window cases cover the existing control/event surface plus
  adoption identity, duplicate/inactive rejection, close veto, reentrant close,
  stale handles, and unchanged ordinary allocation.
- Eight ordinary AppKit focus/presentation cases pass after sharing the runtime.
- Sixteen production WebKit cases cover native/Stage 0, `-O0`/`-O2`, Vite/packaged,
  and successful/stopped-manager adoption with strict warnings and UBSan. They
  verify adoption before reply, native hide/show/title, a cancelled close,
  committed DOM closure, terminal routing before the Z closed callback, and
  reentrant native retirement. Each case uses a bounded process group.

The [adoption matrix](../../spikes/related-windows/results/2026-09-13/window-adoption.json)
is separate from earlier allocation/readiness evidence. Optional protocol-adapter
storage exposed upstream compiler inference, generated-name, and ARC field
cleanup gaps, fixed in Z commit `20bfaf18`. Z now tests both frontends at both optimization levels, including
exactly-once destruction of the adapter's Z controller. This is not a claim of
identical optional layouts, whole-app leak freedom, or first-paint performance.

At that checkpoint, public creation remained gated on family-wide cancellable close preflight,
document-bound unsolicited events/terminal delivery, and broader owner,
navigation, and renderer retirement coverage. The private prepare entry is still
root-owner-only. No new public API, configuration, or permission was introduced.

### Family close preflight checkpoint

Related adoption records the exact live parent `Window` identity, not merely its
string ID. A stale parent or another manager's identically named window is
rejected. Parentage is assigned only at adoption and cannot be changed later.

Before an owner closes, the manager snapshots its logical subtree and publishes
the existing synchronous Z `closeRequested` event to each affected window.
Any veto refuses that attempt without framework teardown or task cancellation.
Reentrant attempts to close an overlapping family are refused. If a listener
adds/removes/replaces a family member or stops the manager, the attempt is also
refused; a fresh request can inspect the new state. This is not a rollback of
arbitrary listener side effects: a listener that explicitly commits native
closure has already changed the application.

After acceptance, committed retirement revokes native document routing and
cancels descendant task controls. Logical subtree removal is idempotent, and
closed listeners cannot resurrect stale controls. Committed DOM/native closure
does not start a second cancellable preflight. Frontend asynchronous vetoes are
not introduced by this work.

Validation:

- 28 headless window cases cover parent identity, nested families, vetoes,
  reentrancy, changed membership, terminal lookup, and ordinary controls.
- Eight ordinary AppKit focus/presentation cases remain green.
- 24 production WebKit cases cover native/Stage 0 × `-O0`/`-O2` × Vite/packaged
  × adopted/stopped-manager/family-close scenarios. A real child veto preserves
  both windows and documents; a later accepted owner close retires both.
- Four registry cases run real Z tasks: work already started completes after a
  veto; accepted close cancels running descendants while unrelated work finishes.
- The packaged Z Notes smoke, TypeScript checks, and 70 focused runtime/CLI tests
  also pass. Native probes use strict Clang warnings, UBSan, and bounded process
  groups; these are correctness checks, not new performance measurements.

Evidence: [native WebKit family close](../../spikes/related-windows/results/2026-09-13/family-close.json)
and [real task lifetime](../../spikes/related-windows/results/2026-09-13/family-close-tasks.json).
The task test exposed upstream Z timer-frame early completion, match-subject
closure preparation, borrowed class-field emission, and inline owned-result
transfer gaps. Z commit `7b62afad` fixes them with exact destructor-count regressions on both
frontends and optimization levels. Dedicated worker-to-main linear timer
segments with early completion remain a diagnosed native-compiler boundary;
ordinary main-executor tasks are covered here.

At that checkpoint, next was document-bound unsolicited terminal delivery, then broader owner,
navigation, and renderer retirement cases before the public factory/demo.
The private production prepare entry is still root-owner-only: headless nested
family evidence does not claim an exposed nested creation API. Styling and
injection proposals remain separate and unapproved.

### Document-bound terminal delivery checkpoint

The production coordinator now sends terminal notices after committed native
routing/window retirement. Delivery checks the original owner's native document
identity before submitting JavaScript, then checks its token again inside the
actual receiving realm. A queued notice cannot invalidate a replacement page's
handle or a child with the same window ID and a different document token.
Duplicate/unknown notices are ignored. Native close does not await evaluation,
listener execution, Promise settlement, or a JavaScript acknowledgement; a dead
or blocked observer realm still cannot be promised JavaScript cleanup.

The internal bootstrap hook connects the already-tested
`RelatedDocumentLifetime` to native delivery. The private creator registers it
after authenticated preparation but **before `window.open`**, not after awaiting
creation. Thus the lifetime object can remember a close that precedes the
consumer's continuation, without retaining an unbounded inbox of unknown
terminal messages. Failed creation detaches the observer; delivered invalidation
removes it before cleanup; owner rebind/disposal drains remaining observers.
The map is allocated only when related documents are observed and is not on the
ordinary service-request path.

The public factory remains unexported. Its future integration must preserve this
prepare → observe → open ordering, detach on every failed creation, and check the
lifetime before exposing a handle. The immediate-close fixture deliberately
delivers a private success reply after native closure to test this race; it does
not redefine public creation as successful for an already-retired document.

The private owner probe now bundles the real lifetime helper, rather than an
instrumentation-only invalidation callback. It verifies pending child-Promise
rejection, unchanged owner requests, queued and late one-shot subscriptions,
duplicate suppression, and closure immediately after adoption. Its held request
is instrumentation; real native-task cancellation remains the separate registry
matrix from the preceding checkpoint.

See [terminal-delivery evidence](../../spikes/related-windows/results/2026-09-13/terminal-delivery.json)
for native/Stage 0 × `-O0`/`-O2` × Vite/packaged × adopted/stopped/family/immediate
cases. Broader owner/navigation/renderer-loss integration and the public
factory/demo remain next. This introduces no public API, permission, injection,
or styling change.

The packaged Z Notes regression also passes. Its embedded bootstrap exposed a
C11 trigraph-escaping bug in Z (`??=` inside JavaScript source), fixed upstream
in `5fa6338d` without rewriting the bootstrap or suppressing compiler warnings.
The native compiler was rebuilt to a byte-identical fixed point before the
final 32-case matrix. The 82 focused runtime/CLI tests and TypeScript/type tests
also pass; all native cases use bounded processes and UBSan, not ASan.

### Navigation and renderer-retirement checkpoint

The production probe now installs `createDesktopNavigationDelegate` for the
owner instead of duplicating its commit handling in a fixture delegate. Related
children already use their production navigation/UI delegates. This checkpoint
needed no new production API or language workaround: it exercises the callbacks
and identity machinery already shipped.

| Case | What is exercised |
| --- | --- |
| Owner replacement | Real same-origin navigation retires the old subtree; the new page receives a new identity and ignores an old-token reply using its reused request ID |
| Owner termination | Inject the documented termination callback twice through the real adapter, then navigate to a new owner page; native retirement is terminal before recovery |
| Child replacement | Real reload of the identical shell URL still retires the original document rather than silently replacing its handle |
| Child termination | Inject the real installed adapter's termination callback twice; the surviving owner rejects retained child work and continues its own requests |
| Refused child navigation | An attempted cross-origin navigation is cancelled by the existing narrow child policy and retires the child; it does not load the external page |

The injected cases first send callbacks with the wrong WebView and assert that
both live documents remain unchanged. They do not kill a WebKit process, use a
private WebKit API, or test actual crash scheduling/shared-process fate. That
distinction matters: native teardown can be guaranteed without promising JS
cleanup in a destroyed observer realm. The owner-replacement case deliberately
has the *new* page verify success instead of waiting for old-page callbacks.

Every retirement case requires native acknowledgement that its intended branch
started. The held-request handshake also waits for actual child-message receipt;
it no longer assumes messages from different WebViews arrive in JS call order.
Retained request rejection here is instrumented bridge work, while the separate
headless registry matrix verifies cancellation of already-running Z tasks and
completion of unrelated work.

All 40 native/Stage 0 × `-O0`/`-O2` × Vite/packaged cases pass with strict warnings,
UBSan, empty stderr, and no timeouts. The
[dated retirement evidence](../../spikes/related-windows/results/2026-09-13/retirement.json)
is separate from the earlier close matrix. The
[32-case creation/close regression](../../spikes/related-windows/results/2026-09-13/retirement-regression.json)
also passes with the production owner delegate, alongside four real-task
registry cases, 46 focused runtime tests, and both TypeScript checks.
Public factory integration still
needs its final creation-authority audit, particularly actual subframe attempts
and the current root-only prepare path. Styling/injection remain unapproved and
unchanged; actual renderer-crash stress is not represented by this callback test.
