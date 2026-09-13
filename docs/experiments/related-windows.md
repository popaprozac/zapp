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
scheduling, failed navigation, and cancellation ordering remain test gates.

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
- Child native closure cancels pending native work without unregistering its
  owner/sibling bridge. Accepted owner closure/replacement invalidates both
  children and their pending work; a replacement owner gets a working endpoint.

These are platform-oracle results, not a production Zapp decoder, capability
system, or Z interop implementation. The native operation is an instrumented
echo, not a generated Z service. The token is reply-domain/freshness correlation,
not a substitute for origin checks or a permission credential. Bootstrap is
installed at document start but this oracle activates it at navigation finish;
preload-time requests and `about:blank` bridge readiness remain unproven.

Native cancellation and JavaScript promise settlement are separate. A promise
created by a child may be retained in its owner; deleting native pending work
does not reject that promise. Document invalidation must also settle those
retained promises, without relaying ordinary service payloads through the owner.
This remains an explicit integration gate, as do family close cancellation and
portal unmount ordering. The oracle conservatively tears down children when
owner replacement starts; it does not establish failed-navigation UX policy.

### Remaining constraints

1. **Trust family, not per-window isolation.** Mutually scriptable windows can
   invoke each other's functions and bridges. Do not claim that a low-authority
   child remains isolated from a higher-authority owner. Deliberate compatible
   content/capability policies before granting any native bridge to children.
2. **Explicit ownership and lifetime.** Decide what happens when an owner hides,
   closes, reloads, crashes, or navigates. Decide child close cancellation and
   portal unmount ordering. No accidental orphaned framework roots.
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
- [ ] Settle retained child promises on invalidation and prove cancellation/unmount
      ordering without blocking native window closure on frontend cleanup.
- [ ] Add independent oracle tests for owner teardown/reload, long-hidden owner,
      child navigation, capability mismatch, and cleanup/leaks before integration.
- [ ] Reproduce the mechanism in checked Z interop; surface any upstream gaps
      instead of growing a production Objective-C implementation.
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
