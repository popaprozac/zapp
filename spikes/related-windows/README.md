# Related-window DOM and shared-UI experiment

Status: **macOS feasibility established; performance promising; not a Zapp API.**

This isolated AppKit/WKWebView oracle asks whether one frontend owner can drive
DOM in several native windows directly. React portals are the demonstration,
not the native abstraction: the key is a script-accessible related window's
document, with ordinary object/function references and same-origin enforcement.

Start with [why, findings, and next steps](../../docs/experiments/related-windows.md).
See [BENCHMARKS.md](BENCHMARKS.md) for the three-way measurements and limits.

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
bun run benchmark
```

Use `bun run test`, not Bun's test-discovery command. For a quick benchmark
wiring check: `BENCH_RUNS=1 bun run benchmark`; the saved baseline uses five
rounds. No root workspace dependency, script, lockfile, or CI changes are needed.

All commands briefly open native windows and close them automatically. They
use an ephemeral loopback server, stopped in `finally`, and locally bundled
scripts. Dependency installation may access the network; the native probes do
not download remote scripts or use a running Z Notes instance or Vite server.

- Feasibility: strict Clang warnings and UBSan; native 15-second watchdog,
  external 20-second process-group deadline per case.
- Direct bridge: `-O0` and `-O2` with strict Clang warnings and UBSan; native
  20-second watchdog and external 25-second process-group deadline per case.
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

## Direct bridge follow-up

`bun run test:bridge` runs twelve cases: HTTP and custom protocol, `-O0` and
`-O2`, each with concurrent round trips, owner closure, or owner replacement.
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

The dated [direct-bridge.json](results/2026-09-12/direct-bridge.json) retains all
twelve runs, 236 JS assertions, 28 child creations/closures, and native
observations. New runs write ignored `.artifacts/direct-bridge-results.json`.
This is a private oracle protocol and instrumented native echo, not a public
API, full Zapp service integration, or a new throughput benchmark.

Important remaining gates: rejecting child promises retained in the owner when
their document disappears; family cancellation and unmount ordering; failed
navigation behavior; early document-start/`about:blank` readiness; sustained
hidden-owner scheduling; and production capability-profile enforcement. This
probe cancels native pending work but does not claim retained JS promises settle.

## Boundaries

This does not prove production navigation/CSP/COOP policy, different capability
profiles within a scriptable family, complete owner reload/destruction/crash UX,
HMR, prolonged background operation, leak freedom, OS input, IME/accessibility,
complex CSS/framework integrations, or Windows/Linux support. Programmatic DOM
clicks are not synthesized native input. UBSan does not establish leak freedom.
Renderer process identities are not measured or promised.

Related windows share trust and owner/scheduling coupling. They are not a
replacement for independently isolated windows, and a headless JS worker cannot
provide the missing DOM owner. Public syntax and lifecycle rules remain open.

## Files

- `probe.m`, `app.jsx`, `run.ts`: feasibility host, React assertions, bounded runner.
- `benchmark.m`, `bench.jsx`, `benchmark.ts`: three native/context variants and measurements.
- `direct-bridge.m`, `direct-bootstrap.js`, `direct-app.jsx`, `direct-bridge.ts`:
  separate child native endpoints, concurrent replies, and native lifetime checks.
- `types.ts`: benchmark result shape for editor/typechecking support.
- `results/2026-09-12/`: original feasibility, benchmark summary, and raw observations.
- `.artifacts/`: ignored results of local reruns.
