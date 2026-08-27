# Z native core

Status: Phase 0 complete; Phase 1 typed ingress, Z-owned AppKit/WebKit identity,
generated typed service round trips, and structured suspending service delivery
through the real WebView complete, August 2026.

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
5. links the generated embedding header and archive into the CLI output;
6. initializes a process-wide Z `Application` through the generated runtime
   initializer, routes owned UTF-8 messages through Z, and shuts the root down
   deterministically;
7. asks `z metadata` for checked public symbols and service-registration calls,
   then generates transport-independent typed TypeScript service bindings;
8. links either the default AppKit/WebKit application host or the focused
   strict-C bridge host used by the non-UI regression; and
9. bundles the canonical `bootstrap/webview.ts` source and generated browser
   service facade, then injects both through a `WKUserScript` at document start.

The route is no longer a pass-through smoke. Z's source-backed `std/json`
parser decodes the WebView envelope into `BridgeMessage`, preserves request
identities through the full `u64` range, dispatches `__zapp:ping`, and returns
an `Option<BridgeResponse>` to the host. Request/response invokes produce
`some(response)`; fire-and-forget bridge actions, events, worker messages, sync
signals, and cancellation produce `none`. Arbitrary `a` payloads are serialized
at the ingress edge and do not become the core's internal object model.

The default executable is now a visible AppKit/WebKit application. Z creates
and owns the window, WebView, configuration, content controller, protocol
handler, and registration guard. Its generated browser binding calls the
Z-owned `NotesService`; Z decodes and dispatches the message, and the typed
response updates the DOM before deterministic window and runtime shutdown. The
Objective-C host owns the process/run-loop adapter, response delivery through
WebKit, and smoke-test observation rather than application object construction
or message-body validation.

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
bootstrap and generated Notes binding at document start, and stays open until
the user closes its window. Clicking the visible button calls
`notes.create(...)`; native delivery resolves it through `_onInvokeResult()`
and the binding restores the exact `u64` identifier as `bigint` before updating
the DOM. `spike:z-notes:smoke` opts into the bounded automation mode: it clicks,
verifies the DOM, prints the response, and closes. Both use the same staged
archive and generated embedding header as an ordinary `ZAPP_NATIVE_LANG=z`
build.

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
z 0.1.0-dev revision 2026-08-25.1 compiler-api 2
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
95,760 bytes. The current 445 KB / 26 MB / roughly 135 microsecond WebView
baseline remains the oracle until Phase 1 performs equivalent work. Z must then
report clean and incremental build time, binary and bundle size, idle memory,
startup, bridge latency, allocations/copies, and deterministic shutdown against
the same app.

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
are now separate source graphs, and one Notes
project drives both the WebView and strict-C embedding hosts. Remaining work
includes typed invocation error/cancellation/permission composition, zjs host
attachment, and ASan or equivalent leak evidence on a compatible host.
