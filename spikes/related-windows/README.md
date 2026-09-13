# Related-window DOM and shared-UI experiment

Status: **macOS feasibility established; performance promising; not a Zapp API.**

This isolated AppKit/WKWebView oracle asks whether one frontend owner can drive
DOM in several native windows directly. React portals are the demonstration,
not the native abstraction: the key is a script-accessible related window's
document, with ordinary object/function references and same-origin enforcement.

Start with [why, findings, and next steps](../../docs/experiments/related-windows.md).
See [BENCHMARKS.md](BENCHMARKS.md) for the three-way measurements and limits.
The [approved public contract](../../docs/plans/related-windows.md) now has runtime
types and a separately tested lifetime helper. The public factory/native bridge
creation is still pending; production document routing is now integrated and
tested separately from this oracle.

## Why Objective-C here?

The small native host isolates public WebKit behavior from compiler/framework
integration. Like the window-resize research oracle, it is never linked into
Zapp, Z Notes, or shipped applications. A future implementation belongs in Z
using checked interop; this experiment does not authorize a new production
Objective-C layer or a public API.

## Run

Requires macOS 14+, Xcode command-line tools, Bun, and a visible unlocked desktop.
Verified on macOS 26.4 (25E5223i), Apple Silicon, system WKWebView. React and
React DOM are pinned to 19.2.0 in this private, independent package.

From the repository root:

```sh
cd spikes/related-windows
bun install --frozen-lockfile --ignore-scripts
bun run test
bun run test:bridge
bun run test:checked-z
bun run test:checked-lifetime
bun run test:registry
bun run test:document-routing
bun run benchmark
```

Use `bun run test`, not Bun's test-discovery command. For a quick benchmark
wiring check: `BENCH_RUNS=1 bun run benchmark`; the saved baseline uses five
rounds. No root workspace dependency, script, lockfile, or CI changes are needed.

The UI commands briefly open native windows and close them automatically. They
use an ephemeral loopback server, stopped in `finally`, and locally bundled
scripts. Dependency installation may access the network; the native probes do
not download remote scripts or use a running Z Notes instance or Vite server.

- Feasibility: strict Clang warnings and UBSan; native 15-second watchdog,
  external 20-second process-group deadline per case.
- Direct bridge: `-O0` and `-O2` with strict Clang warnings and UBSan; native
  20-second watchdog and external 25-second process-group deadline per case.
- Checked Z: native and Stage 0 emission, each at `-O0`/`-O2` with UBSan;
  15-second native timer and 20-second external process-group deadline. Each
  emission has a 120-second deadline and Clang compilation a 30-second deadline.
- Benchmark: optimized `-O2 -DNDEBUG`, no sanitizer; native 30-second watchdog,
  external 35-second process-group deadline per case.
- Compilation: 30-second deadline. Interrupt/timeout handlers stop the harness
  process group. No ASan or system-setting changes.

Generated binaries, symbol files, bundles, dependencies, and `.artifacts/`
are ignored. Dated evidence in `results/2026-09-12/` is preserved separately;
rerunning never overwrites it. The benchmark raw JSON is compacted losslessly.

## Feasibility cases

| Owner | Child | Baseline result |
|---|---|---|
| HTTP loopback | about:blank | PASS |
| HTTP loopback | Same-origin page | PASS |
| HTTP loopback | Other host | DOM access rejected, PASS |
| zapp://probe | about:blank | PASS |
| zapp://probe | Same-origin page | PASS |
| zapp://probe | zapp://other | DOM access rejected, PASS |

All four positive cases verify separate documents/realm intrinsics, opener
identity, direct DOM access, shared object/function identity, React Context
identity, portal rendering, programmatic child button events updating both
views, briefly hiding the owner, and closing/recreating the child while retaining
owner state. Negative cases wait for native navigation completion, avoiding the
initial about:blank false positive. Native child create/close counts must match.
Six runs passed, with 88 assertions and empty stderr in the saved baseline.

The native delegate constructs the child with WebKit's supplied configuration
and lets WebKit navigate it. It does not create an arbitrary independent
WebView and attempt to manufacture a DOM handle over IPC. No private API is used.

## Production bridge lifetime in checked Z

`bun run test:checked-lifetime` uses `checked-z/lifetime.zs` with the real bundled
WebView bootstrap and the owner's `RelatedDocumentLifetime` helper. No handwritten
Objective-C source is used by this host. It requires the Zapp root dependencies
as well as the local native Z compiler; it uses the same process deadlines and
UBSan matrix as the smaller checked-Z creation probe.

Four runs (native/Stage 0 × `-O0`/`-O2`) pass with empty stderr. Separate native
bridge-ready and DOM-ready signals precede exposing the child to the owner.
The child bridge creates its own Promise and receives a direct native reply.
After DOM closure, Z retires native routing and closes the window before sending
an identity-checked lifecycle notification to the owner. The owner settles a
retained child Promise using the real pending table; early/late cleanup queues
once each, and the retired bridge cannot dispatch another request.

This remains a single-child HTTP fixture. It does not implement the production
family registry, permission inheritance, navigation/security audit, or real Z
task cancellation. The instrumented held request intentionally never replies.
Results are written to ignored `.artifacts/checked-z-lifetime-results.json`;
the [dated evidence](results/2026-09-13/checked-z-lifetime.json) is retained separately.

## Headless native document registry

`bun run test:registry` needs no WebKit, visible desktop, or network server. It
executes the framework's internal Z registry, using the actual immutable
capability selection and pending task controls. Native and Stage 0 emission each
run at `-O0`/`-O2` with UBSan. Emission is bounded at 120 seconds, compilation at
30 seconds, and each executable at 10 seconds with process-group termination.

The test covers separate shell/bridge readiness, unchanged inherited grants,
partial-child cleanup, nested descendants, live siblings, owner replacement,
window-ID and request-ID reuse, stale/duplicate completion, delayed task-control
attachment, and cancellation of suspended Z work. An explicit task-start check
prevents a cancellation-before-start case from masquerading as in-flight proof.

The registry is not yet wired into the production macOS window manager or the
checked-Z WebKit fixture above. No public factory is exposed. Native source/origin
authentication and family close veto are still separate integration gates.
Results go to ignored `.artifacts/registry-results.json`; the
[dated evidence](results/2026-09-13/registry.json) is retained separately.

## Production document routing across navigation

`bun run test:document-routing` runs the framework's `BridgeDocument`, private
transport, and real bundled WebView bootstrap in a checked-Z WebKit host. It
commits two pages in one WebView. Both pages use request ID `1`, but native
retirement rejects the original ticket and a deliberately queued old-token reply
of `99` cannot resolve the replacement page's Promise. The current reply is `42`.

The fixture validates its exact WebView/controller, main frame, and loopback
URLs before calling the production transport. It is not a replacement for the
packaged Z Notes smoke's configured-origin and subframe checks. It does not
exercise related-child creation, actual renderer crashes, BFCache restoration,
unsolicited event routing, or family-wide close preflight. The held request here
is instrumentation; the headless registry probe separately tests real Z tasks.

Native and Stage 0 emission each run at `-O0`/`-O2`, with strict Clang warnings
and UBSan. Each emission is bounded at 120 seconds, compilation at 30 seconds,
and execution at 15 seconds with process-group termination. A native run-loop
iteration bound provides a secondary deadline; the loopback server stops in
`finally`. No remote scripts or ASan are used. Results go to ignored
`.artifacts/document-routing-results.json`; the
[dated evidence](results/2026-09-13/document-routing.json) is retained separately.

This probe exposed and helped fix Stage 0's omission of task-handle runtime
support in synchronous programs that only store `TaskControl`/`TaskScope`.
No dummy async function or native shim was added to the fixture.

## Direct bridge follow-up

`bun run test:bridge` runs sixteen cases: HTTP and custom protocol, `-O0` and
`-O2`, each with concurrent round trips, owner closure, owner replacement, or
retained-Promise/cleanup lifecycle checks.
It installs a separate `WKUserContentController` on each WebKit-supplied child
configuration and verifies direct native request/reply routing. Children load
only fixture HTML and an injected bridge, not another React bundle.

Native observations prove distinct sender identities, simultaneous request ID
reuse, rejection of payload-spoofed identities, actual subframe/cross-origin
attempts, old-document token rejection, native close/reload invalidation, and
survival of the owner's/sibling's registration after a child closes. React
Context and direct object identity still work. A portal's owner-defined
callback uses the owner's bridge; calling the child-defined bridge function
uses the child's bridge and returns a promise from the child's realm.

The earlier [direct-bridge.json](results/2026-09-12/direct-bridge.json) retains
twelve runs, 236 JS assertions, 28 child creations/closures, and native
observations. The expanded [direct-lifecycle.json](results/2026-09-12/direct-lifecycle.json)
retains sixteen runs, 344 assertions, and 36 matched child creations/closures.
New runs write ignored `.artifacts/direct-bridge-results.json`.
This is a private oracle protocol and instrumented native echo, not a public
API, full Zapp service integration, or a new throughput benchmark.

The lifecycle checks reject child-created Promises observed by the owner and a
surviving sibling, unmount a portal, drain document registries, and ignore stale
invalidation notifications. They deliberately disable child `pagehide` and pause
owner lifecycle processing: the native window still closes, and cleanup settles
the retained Promise when processing resumes. Service payloads are not relayed
through the owner; only the document-lifecycle notification uses that route.

Native child/family close vetoes preserve pending operations and every affected
document before teardown. DOM `window.close()` is a separate terminal path:
WebKit reports it after completion, too late for native preflight cancellation.
The agreed policy keeps Zapp handle requests cancellable and intrinsic DOM closure
terminal, without redefining browser `window.close()`. All disposal/error names
and test hooks here are private fixtures, not new Zapp APIs.

Remaining gates include actual Z task cancellation and service integration;
failed navigation/renderer failure; early document-start/`about:blank` readiness;
sustained hidden-owner scheduling; and production capability-profile enforcement.
Native delayed callbacks are invalidated and their stale replies suppressed,
not physically cancelled. JS reactions can wait on a busy owner even though
native closure does not wait for JS cleanup.

## Checked-Z creation boundary

`bun run test:checked-z` runs the smaller [Z-authored host](checked-z/main.zs).
It needs the sibling `z-lang` checkout and its bootstrapped native compiler;
`Z_NATIVE_COMPILER` can override that executable. The checked-in
[z.json](checked-z/z.json) sits beside the source for header/tooling configuration.
There is no handwritten native source or `raw` block in this host.

Four bounded UBSan configurations pass: native/Stage 0 emission x `-O0`/`-O2`.
Each verifies one successful WebKit-created child, one nullable delegate refusal,
one child-native-child round trip, and one DOM-driven native child close. The
child receives a separate content controller and retained protocol registration,
reads an owner object, and verifies its document/realm intrinsics remain distinct.
The native handler checks the actual message WebView and main frame; the owner
has no service-message handler to relay through. Z retains the child and adapters
until the application loop unwinds.

The [checked-Z evidence](results/2026-09-12/checked-z.json) is separate from the
broader Objective-C lifecycle oracle. This Z port uses only ephemeral loopback
content and one child; it does not yet cover custom protocols, family preflight,
replacement tokens, retained Promises, production capability policy, or origin
validation. Those remain integration work, not implied by this positive test.
Document-start injection here is followed by a real child-page load; this does
not establish a usable bridge in the initial `about:blank` document.

This pressure test found and fixed Stage 0's adapter/helper declaration ordering
for registrations created inside methods or native callbacks. Two separate native
diagnostic mismatches (unknown Array methods and readonly intermediate assignment
paths) are recorded in Z's `docs/ownership-pressure.md` and remain the next
upstream checkpoint. The valid probe source passes both frontends.

## Boundaries

This does not prove production navigation/CSP/COOP policy, different capability
profiles within a scriptable family, complete owner reload/destruction/crash UX,
HMR, prolonged background operation, leak freedom, OS input, IME/accessibility,
complex CSS/framework integrations, or Windows/Linux support. Programmatic DOM
clicks are not synthesized native input. UBSan does not establish leak freedom.
Renderer process identities are not measured or promised.

Related windows share trust and owner/scheduling coupling. They are not a
replacement for independently isolated windows, and a headless JS worker cannot
provide the missing DOM owner. Public syntax and lifecycle rules are recorded in
the approved contract; the production factory remains gated on integration.

## Files

- `probe.m`, `app.jsx`, `run.ts`: feasibility host, React assertions, bounded runner.
- `benchmark.m`, `bench.jsx`, `benchmark.ts`: three native/context variants and measurements.
- `direct-bridge.m`, `direct-bootstrap.js`, `direct-app.jsx`, `direct-lifecycle.jsx`,
  `direct-bridge.ts`: separate native endpoints, concurrent replies, retained
  Promises, cancellation preflight, and nonblocking cleanup checks.
- `checked-z/main.zs`, `checked-z/z.json`, `checked-z.ts`: the narrower Z-owned
  creation/direct-handler/terminal-close boundary, verified through both frontends.
- `types.ts`: benchmark result shape for editor/typechecking support.
- `results/2026-09-12/`: original feasibility, benchmark summary, and raw observations.
- `.artifacts/`: ignored results of local reruns.
