# Worker engines

Zapp workers are JavaScript threads that own a native host bridge
(unlike Web Workers, they can call into Zapp's services / events /
window APIs directly). Each worker picks an engine independently —
the framework dispatches at runtime based on `engine: "..."` in
`zapp.config.ts`.

## The taxonomy

| Tier | Engine | Use when |
|---|---|---|
| **Recommended** (new projects) | **`zjs`** | Default. Cross-platform, ~1 MB, iOS-friendly (no JIT entitlement gymnastics), first-party. Direct value-marshalling host bridge — skips the JS-side `JSON.stringify` other engines pay on `Services.invokeSync`. Web APIs (fetch, WebSocket) ship in zjs's runtime layer as it matures. JIT planned as an opt-in. |
| **Recommended on macOS** | **`bare-jsc`** | JIT via the system JSC framework — zero engine bundle cost on Apple platforms (literally smaller than zjs on macOS by ~300–500 KB). Tradeoff: less streamlined web APIs — you opt into bare-* packages à la carte (`bare-fetch`, `bare-ws`, `bare-crypto`, …). Use when absolute KB and JIT-perf matter on Apple. |
| **Perf opt-in (Win/Linux)** | **`bare-v8`** | JIT on Windows / Linux where there's no system JSC. ~30 MB bundle increase. Only worth it for JIT-heavy workloads (numeric / hot loops / heavy JS). |
| **Niche** | `bare-quickjs`, `bare-mqjs` | Small cross-platform variants for size-constrained targets. zjs is usually the better fit — pick these only if you specifically need that engine's perf or feature profile. |
| **Niche** | `bare-hermes` | Hermes AOT bytecode. Mostly subsumed by zjs's bytecode option (see below) once mature. |

## Platform recommendations

- **macOS**: `zjs` (default) OR `bare-jsc` (near-tie — pick `bare-jsc` for smallest binary + JIT; pick `zjs` for cross-platform consistency). On Apple platforms zjs runs on kqueue + CFRunLoop — no libuv dependency.
- **iOS**: `zjs` (recommended). Same kqueue + CFRunLoop event loop as macOS — iOS Simulator builds end-to-end with no libuv on the Apple path. `bare-jsc` works but Apple denies JIT entitlements to App Store apps, so it runs in interpreter mode with no perf advantage and a larger bundle than `zjs`.
- **Windows / Linux**: `zjs` (default; still on libuv until the platform-native event-loop ports land). Opt into `bare-v8` only if you need JIT-perf and accept the ~30 MB tradeoff.

## Web API hierarchy

> **Globals come from the engine. Bare packages only fill engine gaps.
> If two sources could provide the same API, the engine wins. Pick your
> engine first; pick your packages second to fill what's missing.**

This means:

- On a **bare-*** engine, the provisional `workers.modules: ["fetch"]` in `zapp.config.ts`
  auto-injects `bare-fetch` and exposes `fetch` as a worker global.
- On **`zjs`** (or any non-bare engine), bare-* shims are skipped — if
  the engine ships the API intrinsically (eventually `fetch`, etc.),
  it wins; if it doesn't, the global is undefined and you get a clear
  `ReferenceError`. No silent `Bare.Addon`-shaped failures.
- You **cannot** stack a bare-* package on top of an intrinsic. The
  engine's version is always the one that runs.

## Bytecode (AOT) option

Engines that ship a bytecode pipeline accept `bytecode: true` in the
application worker config:

```ts
workers: {
  application: {
    ticker: {
      script: "src/workers/ticker.ts",
      engine: "zjs",
      bytecode: true,   // CLI compiles to .zbc at build time
    },
  },
},
```

The CLI runs the engine's `compile` step after Vite bundles the
worker, ships the bytecode artifact, and the engine loads it
parse-free. Cold-start win is biggest on iOS where JIT is gated and
parse cost is the dominant startup cost.

**Pipeline status:**
- **`zjs`** ships today — `.zbc` artifacts compile and load end-to-end on
  macOS + iOS Simulator (the kqueue migration unblocked iOS).
- **`bare-hermes`** is in the type as a `BytecodeCapableEngine` for
  forward-compatibility, but the CLI compile step lands with the
  bare-hermes iOS work. Setting `bytecode: true` on `bare-hermes` today
  type-checks but the worker still ships as source — track via the
  pending bare-hermes runtime work.

Setting `bytecode: true` on a non-bytecode engine (`bare-jsc`,
`bare-v8`, `bare-quickjs`, `bare-mqjs`) is a **TypeScript compile
error** (the `ApplicationWorkerConfig` type is a discriminated union).
The runtime would have errored anyway; the type catches it earlier.

## Fallback chain

When a worker requests an engine that isn't compiled into the binary
(via `build.zc`'s `ZAPP_WORKER_ENGINE_*` defines), the dispatcher
falls back through priority order:

```
zjs > bare-jsc > bare-v8 > bare-hermes > bare-quickjs > bare-mqjs
```

The framework logs the downgrade so it's visible in dev.

## Per-worker mixing

A project can mix engines — e.g. a sync-engine worker on `bare-jsc`
for JIT-perf on macOS plus an event-router worker on `zjs` for size.
The CLI compiles in every engine the config references; the runtime
dispatcher picks per worker at create time.

For auto-discovered (webview-spawned) workers — `new Worker("./x.ts")`
in your main bundle — the Vite plugin inherits a single engine choice
when all application workers agree, defaults to `zjs` when the project
hasn't picked, and leaves it to the runtime resolver in mixed-engine
projects.

## Migration cheatsheet

| If you have | Move to | Notes |
|---|---|---|
| `engine: "bare-quickjs"` | `engine: "zjs"` (usually) | Both small + cross-platform. zjs has the direct host bridge perf wedge. |
| `engine: "bare-hermes"` | Stay or move to `engine: "zjs"` + `bytecode: true` | zjs's bytecode covers Hermes's main iOS use case. |
