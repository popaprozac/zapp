# Z native core

Status: Phase 0 complete; Phase 1 typed ingress, dynamically created Z-owned
AppKit/WebKit windows, generated typed service round trips, and structured
suspending service delivery through real WebViews complete, August 2026.

Zapp's reusable native core lives under `native/z/framework/`; the first
application-owned source graph lives under `spikes/z-notes/zapp/`. It is a
from-scratch Z implementation, not a translation of the current Nim or Zen-C trees. Those
implementations remain the behavioral and performance oracle until the Z core
reaches equivalent application behavior and measurement coverage.

## What works now

`ZAPP_NATIVE_LANG=z` routes the ordinary CLI native compilation seam through
the Z builder. The builder:

1. resolves `ZAPP_Z_COMPILER`, the sibling fixed-point compiler, or `z` from
   `PATH`;
2. runs `z version` and validates the exact language, compiler revision, and
   compiler API in `native/z/compiler-contract.json`;
3. stages the reusable framework and project-owned `zapp/` sources in an
   isolated workspace under the application's gitignored
   `.zapp/z-native-core/` directory;
4. builds `libzapp_core.a` with the Z compiler;
5. links the generated native adapter archive and compiler-embedded Z asset
   catalog into the CLI output;
6. initializes a process-wide Z `Application` through the generated runtime
   initializer, routes owned UTF-8 messages through Z, and shuts the root down
   deterministically;
7. consumes the checked `z metadata` graph already validated from the persistent
   frontend cache or produced by the current frontend preflight when every
   module, package manifest, compiler contract, and compiler identity is still
   current; otherwise it refreshes the graph from the isolated workspace, then
   generates transport-independent typed TypeScript service bindings;
8. links either the default AppKit/WebKit application host or the focused
   strict-C bridge host used by the non-UI regression; and
9. bundles the canonical `bootstrap/webview.ts` source and generated browser
   service facade, then injects both through a `WKUserScript` at document start;
10. compiles the WebView origin, bootstrap, and `webview.inject` catalog into
    a generated typed Z module, then lets each `WindowOptions.inject` select
    its trusted profile set before navigation;
11. expands `security.capabilities` service selectors against the checked
    service manifest, compiles exact grants into immutable Z collections, and
    enforces the originating window's selected profiles before dispatch.

The route is no longer a pass-through smoke. Z's source-backed `std/json`
parser decodes the WebView envelope into `BridgeMessage`, preserves request
identities through the full `u64` range, and distinguishes framework responses,
handled fire-and-forget operations, and messages available to another router.
This prevents a recognized action from accidentally falling through as a
service invocation. Arbitrary `a` payloads are serialized at the ingress edge
and do not become the core's internal object model.

The default executable is now a visible multi-window AppKit/WebKit application.
Z creates and owns each window, WebView, configuration, content controller,
protocol handler, and registration guard. A per-window native registry retains
the run-loop-facing graph and routes each WebKit response by a stable native
identifier; Z owns each window's pending-request namespace and public identity.
The primary WebView invokes the focused frontend `createWindow()` factory after
the application loop starts, proving dynamic realization rather than
startup-only enumeration. The framework handles the built-in operation before
application service dispatch and calls the same Z-owned `WindowManager`. The
child inherits its creator's capability profiles; Web content cannot submit a
different profile list. Native-authored windows may select named profiles in
`WindowOptions`, while unknown names fail window realization with a typed
`WindowError`.

The focused frontend `WindowHandle` operations `show`, `hide`, `setTitle`, and
`close` now traverse that same production bridge and call the Z-owned
`WindowManager` on `thread.main`. They are intentionally fire-and-forget, so a
recognized action is consumed without manufacturing an invoke response;
malformed payloads and unknown window identities fail closed as no-ops. The Z
Notes smoke changes the native title after a typed service round trip, proving
WebView -> Z -> AppKit composition rather than only the manager seam.
The interactive page also exposes visible rename, temporary hide/show, and
close controls so the same production route can be exercised by hand.

Each Z-owned `Window` also exposes a typed, main-executor event surface. Event
channels are ordinary Z objects rather than stringly framework callbacks:

```zs
import {
  WindowCloseRequestedEvent,
  WindowClosedEvent,
} from "zapp/window";

const closeRequested = try window.events.closeRequested.subscribe(
  move (in event: WindowCloseRequestedEvent): void => {
    if (hasUnsavedChanges()) event.cancel();
  }
);
const closed = try window.events.closed.subscribe(
  move (in event: WindowClosedEvent): void => {
    console.log(`window ${event.windowId} closed`);
  }
);

window.close();
```

The focused initial surface includes `focused`, `blurred`, `resized`, and
`closeRequested` and terminal `closed` channels plus `window.events.all`.
`window.close()` requests the operation; it does not claim that closing has
already completed. `closeRequested` is dispatched synchronously on the main
executor before AppKit or the inactive backend commits the close. Any handler
may call `event.cancel()`, and cancellation is monotonic for that request. If
the request proceeds, `closed` is published exactly once after the manager has
removed the native and Z-owned window state.

Multiple subscribers are allowed. A specific channel publishes before `all`,
and each channel preserves subscription order. `window.events.all` observes the
same `WindowCloseRequestedEvent`, so an aggregate handler may also cancel it.
`unsubscribe()` is explicit and idempotent; dropping the subscription also
unregisters it deterministically through `deinit`. Once `closed` publishes, all
channels reject later subscriptions and release their handler registries before
native shutdown. `WindowEventSubscription` remains useful when a subscription
must be stored or passed independently; local inference normally keeps the
common case concise.

The AppKit delegate callbacks enter Z through the native registration owner and
publish under a dedicated structured `TaskScope`. Shutdown closes and joins that
scope before releasing the Z-owned window graph, so native callbacks cannot race
framework teardown. The public event objects remain platform-neutral; future
backends provide their own native callback adapters.

The Objective-C host owns the process/run-loop adapter, native service-response
delivery, and smoke observation rather than application object construction or
message-body validation. The WebKit custom-scheme controller and its request
policy are Z-owned: origin/path validation, SPA fallback, asset selection, MIME
and encoding choice, response construction, and task delivery all live in
`scheme-handler.zs`. The generated asset catalog is also Z: module-local
`embed.StaticBytes` values refer directly to process-lifetime compiler storage,
and raw assets become zero-copy `NSData` views. Native glue only decodes Brotli
bytes into an ownership-transferring `NSData`. Z constructs typed Foundation
errors and fails WebKit scheme tasks directly.
WebView bootstrap, identity, and configured CSS/JavaScript injection policy are
also Z-owned in `webview-injections.zs`: profile validation, duplicate
suppression, JSON-safe source quoting, phase mapping, and `WKUserScript`
registration happen through checked Objective-C interop. The generated
`configured-webview.zs` module carries the origin, bundled bootstrap, and
ordered injection sources as ordinary typed Z values; production native glue
no longer exposes or reads a parallel C configuration table.
Initial URL resolution and application-origin navigation policy live in
`navigation.zs`. A retained Z-owned `WKNavigationDelegate` adapter handles
native completion blocks directly, permits subframe and same-origin main-frame
navigation, rejects external main-frame navigation, and reports load failures.
Window request construction, loading, centering, and initial visibility are
also ordinary checked Z/AppKit calls rather than host-side Objective-C policy.

The consuming `Application` also owns a separate lifecycle registry. Typed
main-executor start hooks run before the blocking platform loop; stop hooks run
after it returns. Startup failure rolls back the successfully started prefix in
reverse order, while normal shutdown attempts every stop before propagating a
typed lifecycle error. Ordinary owned service resources still prefer `deinit`;
the explicit lifecycle contract is for process-wide orchestration.

Run the focused end-to-end paths with:

```sh
bun run spike:z-bridge
bun run spike:z-notes
bun run spike:z-notes:smoke
bun run spike:z-notes:dev
bun run spike:z-notes:dev-smoke
```

The Z Notes development runner uses the fixed-point native `z` driver. Manual
`TaskScope` construction, owned capture transfer, main-executor placement, and
scope close/join are all native-backed; no Stage 0 override is required.

The strict bridge smoke imports `compileNative`, sets the same language selector
as the CLI, builds the in-tree core, links it, and routes a non-ASCII JSON
envelope with request ID `u64.max`. It verifies the typed response metadata and
exact JSON payload after the C -> Z -> C round trip. It is therefore evidence
for the real build seam rather than a parallel script that can drift from it.

The ordinary Z Notes command builds the default host, injects the production
bootstrap and generated service facade at document start, and dynamically opens
a second diagnostics window through `createWindow()`. The process stops only after the last native
window closes. Clicking either window's visible button calls
`notes.create(...)`; native delivery resolves it through `_onInvokeResult()`
and the binding restores the exact `u64` identifier as `bigint` before updating
the DOM. `spike:z-notes:smoke` opts into bounded automation: it verifies
independent window identities, frontend-safe injection isolation,
cancellation/request routing, and both DOMs before closing every window. Both
use the same staged native inputs and generated Z asset catalog as an ordinary
`ZAPP_NATIVE_LANG=z` build.

The development commands exercise the complete CLI-owned loop: Vite serves the
same logical application URL with its HMR client, the Z-native AppKit/WebKit
host loads it, and closing the app deterministically terminates and awaits the
detached Vite process tree. The bounded smoke distinguishes `hmr=ready` from
the packaged `hmr=packaged` path and verifies that port 5173 is reusable after
shutdown.

The focused `native/z/smokes/async-service/` executable proves the same service
shape without involving WebKit timing. It routes the synchronous health path,
the suspended `AsyncServiceHandler` path, and a deterministic cancellation
path under one `TaskScope`. The cancellation target parks in scheduler-aware
`delay`; cancelling its recorded `TaskControl` removes the timer and proves the
post-delay continuation never executes, while a later service request still
completes. Stage 0 and the fixed-point compiler execute the same smoke.
Synchronous handlers remain in a separate frozen map and retain the direct-call
path.

The desktop application applies that model to a foreign WebKit callback. An
application-owned `TaskScope` accepts each request, keeps it alive through
service suspension, publishes completion on `thread.main`, and is cancelled
and joined before lifecycle shutdown. A main-isolated registry maps WebView
request identifiers to generation-guarded `TaskControl` values; mutable request
objects never cross a task boundary. `CancellablePromise.cancel()`, timeouts,
and standard `AbortSignal` requests therefore reach the corresponding
structured Z task. Cancellation remains cooperative: the browser rejects
immediately, the Z task observes cancellation at a supported suspension point,
and the browser ignores any completion that already won the race.

The routing helper itself is executor-neutral. It awaits the selected service
without claiming UI affinity, then explicitly uses
`await on thread.main finishAndDeliverRoutedResponse(...)` for generation
bookkeeping and native WebView delivery. WebKit currently enters this path on
main, so publication takes the zero-hop fast path. The same router can later be
started on a worker executor without making service code or response decoding
implicitly main-isolated.

## Compiler contract

Z reports an identity shaped like:

```text
z 0.1.0-dev revision 2026-08-31.1 compiler-api 2
```

The language version describes the user-facing language, the compiler revision
is deliberately bumped when Zapp must revalidate compiler behavior, and the API
revision describes the build/embedding contract. This is more useful than
pinning every unrelated Z Git commit and more reproducible than trusting an
executable path. Any mismatch fails before compilation with the observed and
expected values.

## Phase 0 performance checkpoint

Measured on the existing Apple M4 Max development machine, using the release Z
library and a size-optimized strict-C host:

| Metric | Phase 0 result | Meaning |
|---|---:|---|
| Z archive | 4,384 bytes | One exported owned-string route plus embedding runtime |
| Linked lifecycle host | 51,176 bytes | Console smoke only; no AppKit/WebKit or assets |
| Clean staged smoke | 373.6 ms mean, 35.3 ms standard deviation | Five runs, stage removed before each run |
| Cached staged smoke | 314.1 ms mean, 24.8 ms standard deviation | Ten runs after two warmups |

These are the historical pre-JSON baseline numbers, not a product comparison.
The runtime-owned typed JSON archive is 43,704 bytes. Its strict-C smoke host is
71,224 bytes, while the first dynamically linked AppKit/WebKit executable is
95,760 bytes. The current like-for-like Z Notes product checkpoint is a 281,920
byte executable, a 290,816 byte icon-free application bundle, 24 MB idle RSS,
and a 79 microsecond median no-op WebView service round trip. The typed struct
echo probe measures 80 microseconds, so generated DTO handling adds about one
microsecond at this boundary. Z must continue to report clean and incremental
build time, binary and bundle size, idle memory, startup, bridge latency,
allocations/copies, and deterministic shutdown against equivalent applications.

The first typed-service checkpoint adds a frozen function-valued router,
checked Notes handler, synchronized service state, exact integer projection,
and direct embedded-host entry. The measured release strict host grows from
71,216 to 89,168 bytes; its Z archive grows from 43,552 to 56,592 bytes. Three
100,000-call direct `notes.count` runs measured 279.44, 258.85, and 257.00 ns per
call, including lookup, thunk invocation, synchronized read, JSON response, and
C callback. See [Z-owned services](./z-services.md) for the architecture and
measurement boundary.

## CLI and package design are open

The existing command and npm layout are not compatibility constraints. Phase 0
keeps `zapp build` as a stable measurement harness, but the rewrite may improve:

- package boundaries between CLI, runtime, Vite integration, native sources,
  and compiler/toolchain metadata (the repository now declares those existing
  packages as Bun workspaces so one install is authoritative);
- dependency ownership (the Vite plugin now declares its own Babel/esbuild
  runtime surface instead of resolving it accidentally through the CLI);
- staging and incremental native caches;
- compiler acquisition and reproducible toolchain selection;
- generated-binding ownership and diagnostics; and
- the stable package import that replaces the spike's repository-relative
  framework import.

Changes should reduce concepts and generated glue, preserve Bun-friendly
frontend ergonomics, and remain measurable. We do not need to imitate the old
CLI merely because it exists.

## Next exit criterion

Phase 0's exit criterion is satisfied. Phase 1 now has a visible generated
service call through WebView -> Z -> WebView, a generated-runtime-owned Z
`Application`, Z-owned UI identities and retained protocol registration, typed
JSON ingress and dispatch, an embedded-engine direct-service seam, and
deterministic window/run-loop/runtime shutdown. The framework and application
are now separate source graphs, and one Notes project drives dynamic
multi-window WebViews and the strict-C embedding host. The first compiled
permission slice also gates frontend window creation inside Z and returns
structured invocation errors that the TypeScript runtime restores as
descriptive error subclasses. Generated services now preserve owned decoded
request values and typed failures through suspension and explicit main-executor
placement. Synchronous main-isolated service methods are adapted through a
private generated async wrapper, keeping the public method synchronous while
making cross-executor dispatch explicit in generated Z. Remaining work includes
zjs host attachment, broader wire-type coverage, and ASan or equivalent leak
evidence on a compatible host.
