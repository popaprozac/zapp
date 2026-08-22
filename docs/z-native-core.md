# Z native core

Status: Phase 0 complete; Phase 1 AppKit/WebKit vertical slice next, August 2026.

Zapp's future native core lives under `native/z/`. It is a from-scratch Z
implementation, not a translation of the current Nim or Zen-C trees. Those
implementations remain the behavioral and performance oracle until the Z core
completes the first visible WebView round trip.

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
6. initializes the Z runtime, routes one owned UTF-8 message through Z, and
   shuts the runtime down deterministically.

The Phase 0 executable is a strict-C host, not a desktop application. It exits
after the lifecycle smoke. Phase 1 replaces that host with the Z-owned
`Application`, `NSApplication`, `NSWindow`, and `WKWebView` vertical slice.

Run the focused end-to-end smoke with:

```sh
bun run spike:z-bridge
```

The smoke imports `compileNative`, sets the same language selector as the CLI,
builds the in-tree core, links it, and routes a non-ASCII JSON envelope. It is
therefore evidence for the real build seam rather than a parallel script that
can drift from it.

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

These numbers are a compiler/link baseline, not a product comparison. The
current 445 KB / 26 MB / roughly 135 microsecond WebView baseline remains the
oracle until Phase 1 performs equivalent work. Z must then report clean and
incremental build time, binary and bundle size, idle memory, startup, bridge
latency, allocations/copies, and deterministic shutdown against the same app.

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

Phase 0's exit criterion is satisfied: `ZAPP_NATIVE_LANG=z` builds and links
through the ordinary kitchen-sink frontend project without a separate bridge
implementation. Phase 1 is the single-window AppKit/WebKit slice in the
rewrite charter, with JSON decoded immediately into typed Z values rather than
retained as the core object model.
