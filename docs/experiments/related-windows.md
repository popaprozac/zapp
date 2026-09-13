# Related windows: one frontend owner, multiple native documents

Status: research checkpoint, 2026-09-12. **Go for further exploration, not a
shipping feature or approved public API.** macOS/system WKWebView only.

Runnable source: [spikes/related-windows](../../spikes/related-windows/README.md).
Measurements: [benchmark report](../../spikes/related-windows/BENCHMARKS.md).

## Why investigate this?

Independent Zapp windows have independent frontend state and DOM access. Shared
backend/worker state and messages remain appropriate, but detachable inspectors,
editors, palettes, and other closely coordinated UI can accumulate synchronization
code and duplicated frontend bootstrapping.

The question is whether an optional family of related windows can let one
DOM-capable frontend owner keep the UI state/framework tree while rendering
into multiple native window documents. The inspiration is this
[Electron/React portal experiment](https://pietrasiak.com/creating-multi-window-electron-apps-using-react-portals).
React supplies a convenient proof through
[createPortal](https://react.dev/reference/react-dom/createPortal); this should
not become a React-specific native feature. Other frameworks must be evaluated
against the same underlying document/lifecycle capability.

This is distinct from claiming all backend/UI communication is in-process.
The experiment avoids the native message relay for direct related-window UI
coordination; it does not remove WebKit's native/process architecture or make
an unrelated webview's document transferable through ordinary IPC.

## What worked

The isolated host handles WebKit's
[new-window delegate callback](https://developer.apple.com/documentation/webkit/wkuidelegate/webview(_:createwebviewwith:for:windowfeatures:))
using its supplied configuration. A same-origin owner receives a scriptable
WindowProxy, accesses the child's document, and renders a portal there. The
documents and realm intrinsics remain distinct; application objects, callbacks,
and React Context can retain identity across the related contexts.

HTTP and custom-protocol cases pass. Cross-origin negative controls reject DOM
access after child navigation. Native closure counts match. The benchmark adds
a related child with its own React root, so relationship and framework reuse
are not incorrectly treated as one cause.

| Custom-protocol median | Related portal | Related own root | Independent + native relay |
|---|---:|---:|---:|
| Later child: populated + two animation-frame callbacks | 57 ms | 56 ms | 89 ms |
| Update-and-confirm, median amortized run mean | 0.043 ms | 0.046 ms | 0.234 ms |

The 5.4x update-completion difference is about 0.19 ms absolute, not a 5x frame
rate improvement. The related-own-root control shows that most warm-start
advantage in this small app cannot be credited to framework reuse. Frame-paced
measurements were similar. First-child startup is not cold app startup, and
two animation callbacks do not measure physical pixel presentation. Memory,
power, renderer process layout, and full-framework overhead were not measured.

## Design constraints before integration

### Agreed direction after the first review

Independent windows remain the default. Related windows are an explicit,
same-trust family, not a way to make a lower-permission window isolated from
its owner. Each member keeps its own native identity, events, and direct native
bridge; it inherits the family's authority rather than choosing a stronger or
nominally isolated weaker profile. Public construction/binding syntax is still
open, and production capability-catalog enforcement has not been implemented.

The lifetime belongs to the owning document: hiding/minimizing preserves the
family; accepted owner closure or document replacement tears down its children.
Ordinary cancellation must be resolved before destructive family teardown.
An owner crash cannot depend on a JavaScript cancellation callback. Long-hidden
scheduling, failed navigation, and production cancellation integration remain
test gates; the isolated native preflight is covered below.

### Direct-child bridge proof

The follow-up [direct bridge oracle](../../spikes/related-windows/direct-bridge.m)
preserves WebKit's supplied configuration but replaces its user content
controller before child WebView construction. Every child gets a small
document-start bootstrap and its own native endpoint. No React/application
bundle is loaded in the child, and neither request nor response payloads go
through the owner's JavaScript bridge.

Twelve bounded UBSan runs passed: HTTP/custom protocol x `-O0`/`-O2` x ordinary
round trips/owner close/owner replacement. The
[dated evidence](../../spikes/related-windows/results/2026-09-12/direct-bridge.json)
records each assertion and native observation. They verify:

- Two simultaneously live children and the owner use distinct bridges/identities,
  with overlapping request counters, concurrent native replies, and no cross-talk.
- Native sender identity comes from the registered `WKScriptMessage.webView`
  and content controller, not the intentionally forged payload identity.
- A child-defined bridge function still calls native as that child when the
  owner invokes it across realms with its own public transport disabled.
- Shared objects, opener identity, separate documents/realms, and React Context
  survive installing separate content controllers. An owner-defined portal
  callback remains an owner-origin call; DOM placement does not rebind imports.
- Native origin/main-frame checks reject actual cross-origin and subframe
  entry attempts. A fresh document token prevents old-document requests and
  replies from entering replacement state with reused request IDs.
- Child native closure invalidates pending replies without unregistering its
  owner/sibling bridge. Accepted owner closure/replacement invalidates both
  children and their pending replies; a replacement owner gets a working endpoint.

These are platform-oracle results, not a production Zapp decoder, capability
system, or Z interop implementation. The native operation is an instrumented
echo, not a generated Z service. The token is reply-domain/freshness correlation,
not a substitute for origin checks or a permission credential. Bootstrap is
installed at document start but this oracle activates it at navigation finish;
preload-time requests and `about:blank` bridge readiness remain unproven.

### Retained promises and nonblocking native closure

The expanded [lifecycle suite](../../spikes/related-windows/direct-lifecycle.jsx)
passes sixteen configurations: the same origins/optimization levels, with a
fourth lifecycle scenario and native family-veto checks added to owner closure.
Its [separate evidence](../../spikes/related-windows/results/2026-09-12/direct-lifecycle.json)
records 344 JS assertions and 36 matched child creations/closures. This is not
a new performance measurement or a production API.

Native invalidation and JavaScript promise settlement are separate. The oracle
now keeps document-specific child bridge references in the owner. A small native
lifecycle notification disposes the old child bridge through that surviving
owner, rejects its pending promises, and runs cleanup. Ordinary requests and
replies still travel directly between the calling child and native code.

The tests establish:

- A child-created Promise observed from both the owner and a surviving sibling
  rejects with the same error object after native closure. Replacement rejects
  old-document promises without affecting the fresh endpoint.
- Native closure completes even with frontend lifecycle processing deliberately
  paused. Releasing that pause rejects the Promise and unmounts the portal.
  This proves no cleanup-acknowledgement gate, not a real-time JS scheduling bound.
- A native child-close veto preserves its endpoint, portal, and pending reply.
  A child veto during owner-close preflight preserves the entire family before
  any destructive teardown; pending requests then resolve normally.
- Duplicate disposal, stale-token notifications, callback errors, and removed
  subscriptions do not strand other cleanup or dispose a replacement document.
  Family registry entries drain and a retired bridge cannot submit new work.
- DOM `window.close()` also rejects a retained Promise, but does **not** exercise
  the native cancellation preflight.

The close-route distinction is agreed:
[WebKit's delegate contract](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKUIDelegate.h)
reports DOM `close()` only after it has completed. The oracle treats that callback
as terminal cleanup; it cannot restore a closed document by vetoing the containing
native window. Use Zapp's window handle for cancellable close requests, and treat
intrinsic DOM closure as an already-committed terminal path. Both paths still
invalidate native routing and clean up retained document state. We will not
silently intercept or redefine DOM `window.close()`. This is the approved policy
for future integration; the production related-window feature is not built yet.

`PROBE_DOCUMENT_INVALIDATED`, disposal hooks, and test controls are private fixture
vocabulary, not proposed Zapp APIs. Public error shape and cross-realm error
handling still need deliberation. A blocked owner can delay Promise reactions
and portal cleanup even though native closure is not waiting. Renderer failure
and prolonged hidden-owner scheduling are not covered by these checks.

The native delayed blocks still run after invalidation and suppress stale replies;
this is not proof of cancellation propagation into real Z tasks. The oracle
conservatively tears down children when owner replacement starts and does not
establish failed-navigation UX policy. Readiness before navigation finish remains
unproven.

### Remaining constraints

1. **Trust family, not per-window isolation.** Mutually scriptable windows can
   invoke each other's functions and bridges. Do not claim that a low-authority
   child remains isolated from a higher-authority owner. Deliberate compatible
   content/capability policies before granting any native bridge to children.
2. **Explicit ownership and lifetime.** Carry the tested native preflight and
   nonblocking cleanup into Zapp's existing lifecycle machinery. Preserve the
   agreed close-route distinction; deliberate owner crashes and failed navigation.
   Do not assume the platform oracle settles every terminal path.
3. **Navigation is a security transition.** Test dev/prod origin equivalence,
   redirects, external URLs, CSP, COOP, opener removal, and bridge injection.
   Current negative tests are not a complete navigation security audit.
4. **Shared scheduling is a tradeoff.** A slow owner may stall the family. Hidden
   or minimized owners need sustained scheduling tests. Independent windows
   remain useful for isolation and independently expensive workloads.
5. **Framework-neutral primitive first.** React adapters can manage style copying,
   portal mounting, document-scoped APIs, and cleanup above that primitive.
   Focus, keyboard/IME, accessibility, CSS-in-JS, and event assumptions need tests.
6. **Do not assume platform parity.** Prove Windows/WebView2 and Linux behavior
   separately; use a documented unsupported capability if necessary. Do not
   emulate direct DOM identity with a proxy that silently changes semantics.

## Next steps and decision gates

- [x] Public-API WKWebView feasibility with native windows and direct DOM access.
- [x] Same-origin/cross-origin, React context/events, child recreation controls.
- [x] Bounded three-way benchmark with raw evidence and cautious interpretation.
- [x] Independent child native endpoints while preserving DOM/portal relationships,
      including provenance checks and stale-document reply domains.
- [x] Agree on document-owned lifetime and shared family authority in principle.
- [ ] Deliberate Zapp's optional related-window family shape, authority, owner
      lifetime edge cases, and navigation rules with the project owner. No API is locked.
- [x] Settle retained child promises on invalidation and prove cancellation/unmount
      ordering without blocking native window closure on frontend cleanup.
- [x] Native child/family close veto before any teardown, with pending requests
      preserved on cancellation and invalidated on accepted closure.
- [x] Agree that framework close requests are cancellable, while intrinsic DOM
      close is already committed and must still run terminal cleanup.
- [ ] Deliberate the public invalidation error/cleanup contract before integration.
- [ ] Expand oracle tests for renderer failure, long-hidden owner, failed/external
      navigation, capability mismatch, and cleanup/leaks before integration.
- [x] Reproduce the essential creation boundary in checked Z: nullable
      `WKUIDelegate` return, WebKit-supplied configuration, child-owned handler,
      direct native reply, and terminal DOM-close callback.
- [ ] Close the native diagnostic-parity findings recorded in Z's
      `docs/ownership-pressure.md` (unknown Array method, readonly intermediate
      assignment path). Stage 0's nested adapter declaration-order gap is fixed.
- [ ] Port the broader document-token, retained-Promise, and cancellation-preflight
      behavior to checked Z; do not grow the oracle into production native code.
- [ ] Integrate only after those gates with the existing window manager and
      close/cancellation/permission mechanisms, including dev and bundled content.
- [ ] Measure a representative multi-window app with cold/warm startup, process-
      family memory, heavy owner workloads, and actual presentation evidence.
- [ ] Explore other frontend frameworks and other OS backends independently.

This research should not interrupt unrelated main-thread framework work. The
small Objective-C host remains an oracle and is never linked into production.

## Evidence and reproducibility

The [spike README](../../spikes/related-windows/README.md) has commands and exact
scope. The [dated summary](../../spikes/related-windows/results/2026-09-12/benchmark-summary.json)
and [raw data](../../spikes/related-windows/results/2026-09-12/benchmark-raw.json)
retain all 30 successful benchmark runs. Feasibility evidence is
[recorded separately](../../spikes/related-windows/results/2026-09-12/feasibility.json).
Local reruns write ignored artifacts rather than overwriting these snapshots.
The separate [direct bridge evidence](../../spikes/related-windows/results/2026-09-12/direct-bridge.json)
records the follow-up identity, reply, and native-lifetime checks; it is not a
new performance measurement.
The expanded [lifecycle evidence](../../spikes/related-windows/results/2026-09-12/direct-lifecycle.json)
preserves retained-Promise, cancellation-preflight, and delayed-cleanup checks
without overwriting that earlier twelve-case snapshot.
The [checked-Z host](../../spikes/related-windows/checked-z/main.zs) has its own
[four-run evidence](../../spikes/related-windows/results/2026-09-12/checked-z.json):
native and Stage 0 emission at `-O0`/`-O2`, all with UBSan. One allowed and one
refused child creation exercise both sides of the nullable native return, and
the allowed child receives a direct reply before DOM-close teardown. This is
a narrower HTTP-only port, not a claim that the full lifecycle oracle has been
implemented in Zapp or that production navigation/capability policy is complete.
