# Z native core

Status: Phase 0 complete; Phase 1 typed ingress and the first visible
AppKit/WebKit round trip complete, with native-object ownership migration still
in progress, August 2026.

Zapp's future native core lives under `native/z/`. It is a from-scratch Z
implementation, not a translation of the current Nim or Zen-C trees. Those
implementations remain the behavioral and performance oracle until the Z core
reaches equivalent application behavior and measurement coverage.

## What works now

`ZAPP_NATIVE_LANG=z` routes the ordinary CLI native compilation seam through
the Z builder. The builder:

1. resolves `ZAPP_Z_COMPILER`, the sibling fixed-point compiler, or `z` from
   `PATH`;
2. runs `z version` and validates the exact language, compiler revision, and
   compiler API in `native/z/compiler-contract.json`;
3. stages the framework-owned sources in the application's gitignored
   `.zapp/z-native-core/` directory;
4. builds `libzapp_core.a` with the Z compiler;
5. links the generated embedding header and archive into the CLI output;
6. initializes a process-wide Z `Application` through the generated runtime
   initializer, routes owned UTF-8 messages through Z, and shuts the root down
   deterministically;
7. links either the default AppKit/WebKit application host or the focused
   strict-C bridge host used by the non-UI regression; and
8. bundles the canonical `bootstrap/webview.ts` source and injects it through a
   `WKUserScript` at document start.

The route is no longer a pass-through smoke. Z's source-backed `std/json`
parser decodes the WebView envelope into `BridgeMessage`, preserves request
identities through the full `u64` range, dispatches `__zapp:ping`, and returns
an `Option<BridgeResponse>` to the host. Request/response invokes produce
`some(response)`; fire-and-forget bridge actions, events, worker messages, sync
signals, and cancellation produce `none`. Arbitrary `a` payloads are serialized
at the ingress edge and do not become the core's internal object model.

The default executable is now a visible AppKit/WebKit application. Its page
posts through a Z-defined `WKScriptMessageHandler`; Z decodes and dispatches the
message, and the typed response updates the DOM before deterministic window and
runtime shutdown. The Z `DesktopApplication` root owns the handler registration
guard, so shutdown unregisters it exactly once. The Objective-C host still owns
window/WebView construction and rendering plus one narrow dynamic check that
WebKit's `id` message body is an `NSString` before it enters Z as an owned
`String`.

Run the focused end-to-end smoke with:

```sh
bun run spike:z-bridge
bun run spike:z-webview
```

The strict bridge smoke imports `compileNative`, sets the same language selector
as the CLI, builds the in-tree core, links it, and routes a non-ASCII JSON
envelope with request ID `u64.max`. It verifies the typed response metadata and
exact JSON payload after the C -> Z -> C round trip. It is therefore evidence
for the real build seam rather than a parallel script that can drift from it.

The WebView smoke builds the default host, injects the production bootstrap at
document start, opens one window, and automatically clicks the visible bridge
button. The page calls the canonical `bridge.invoke()` API, native delivery
resolves it through `_onInvokeResult()`, and the host verifies the resulting DOM
state before printing the response and closing. It uses the same staged archive
and generated embedding header as an ordinary `ZAPP_NATIVE_LANG=z` build.

## Compiler contract

Z reports an identity shaped like:

```text
z 0.1.0-dev revision 2026-08-22 compiler-api 1
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
- whether app-authored Z lives in the application, a package, or a generated
  build graph.

Changes should reduce concepts and generated glue, preserve Bun-friendly
frontend ergonomics, and remain measurable. We do not need to imitate the old
CLI merely because it exists.

## Next exit criterion

Phase 0's exit criterion is satisfied. Phase 1 now has a visible
WebView -> Z -> WebView round trip, a generated-runtime-owned Z `Application`,
Z-owned retained protocol registration, typed JSON ingress and dispatch, and
deterministic window/run-loop/runtime shutdown. The remaining Phase 1 work is
to move window/WebView identities into Z where that improves the architecture,
replace the dynamic body-check seam when checked Objective-C-owned text
provenance is available, and run the complete path under sanitizers.
