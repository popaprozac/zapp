# Engine selection API — design notes

End-user API for picking the JS engine + web-API modules per worker,
with sensible auto-defaults that "just work" cross-platform.

## Engine identifiers

| ID | Engine | Source | JIT | Web APIs |
|---|---|---|---|---|
| `jsc` | JavaScriptCore via Cocoa `JSContext` | system framework | ✅ macOS, ❌ iOS | none (host bridge only) |
| `txiki` | QuickJS via txiki.js | vendored | ❌ | full (fetch / WS / streams / SQLite) |
| `bare-jsc` | JavaScriptCore via Bare + libjsc | vendored | ✅ macOS, ❌ iOS | à la carte (`bare-fetch`, `bare-ws`, etc.) |
| `bare-v8` | V8 via Bare + libjs (default) | prebuilt | ✅ all | à la carte |
| `bare-quickjs` | QuickJS via Bare + libqjs | vendored | ❌ | à la carte |
| `bare-mqjs` | micro-QuickJS via Bare + libmqjs | vendored | ❌ | à la carte (embedded) |

## Per-worker config

Headless workers (`zapp.config.ts`):
```ts
export default defineConfig({
  headless: {
    ticker: {
      script: "src/workers/ticker.ts",
      engine: "bare-jsc",      // explicit pick
      modules: ["fetch", "ws"], // bare-fetch + bare-ws bundled
    },
    sync: {
      script: "src/workers/sync.ts",
      engine: "auto",           // auto-pick per platform
    },
  },
});
```

Webview-spawned workers — same option on `new Worker()`:
```ts
const worker = new Worker("./worker.ts", {
  engine: "bare-jsc",
  modules: ["fetch", "crypto"],
});
```

(Today the second arg is just `WorkerOptions` from the standard
`HostWorkerOptions` shape; we extend it with a Zapp-specific
`engine` and `modules` override that JSC/txiki ignore.)

## `"auto"` resolution rules

| Platform | Auto picks | Why |
|---|---|---|
| macOS (no modules requested) | `jsc` | smallest binary, system framework, JIT |
| macOS (modules requested) | `bare-jsc` | JIT + à la carte web APIs |
| iOS (no modules) | `jsc` | system framework, App Store safe |
| iOS (modules requested) | `bare-jsc` | adds web APIs without txiki's no-JIT cost |
| Windows | `bare-v8` (when shipped) | JIT — best perf |
| Linux (future) | `bare-quickjs` | smallest cross-platform |

User can always override with an explicit engine string — auto is a
suggestion, not a lock.

## Module presets

To avoid users picking 10 module checkboxes, expose presets that bundle
the common groups:

| Preset | Includes |
|---|---|
| `"none"` | core only — host bridge, timers, events |
| `"web-standard"` | fetch, websocket, streams, crypto, encoding, url |
| `"node-compat"` | fs, path, os, process, http (closer to Node behavior) |
| `"sync-engine"` | fetch, websocket, crypto, structured-clone, sqlite |

Used as:
```ts
{ engine: "bare-jsc", preset: "web-standard" }
```

## Build-time engine inclusion

`zapp/build.zc` keeps the `//> define: ZAPP_WORKER_ENGINE_*` directives
for engine inclusion at link time, but with new entries:

```
//> macos: define: ZAPP_WORKER_ENGINE_BARE_JSC
//> windows: define: ZAPP_WORKER_ENGINE_BARE_V8
```

CLI auto-derives the right defines from `zapp.config.ts` if the user
sets engines at the config level — eliminates the dual-config footgun
where a user picks `bare-jsc` in config but forgets the build.zc
directive.

## Backward compatibility

- Existing `engine: "jsc"` / `engine: "txiki"` keep working; no breaking
  change.
- `engine: "auto"` becomes the new default for newly-created projects;
  the `init` template emits it.
- Apps not using `bare-*` don't pull Bare into their build (cmake-fetch
  + link only happens when at least one worker config requests it).

## Open questions

- **Do `modules` values map 1:1 to npm `bare-<name>` packages, or do we
  curate?** Curating gives us a chance to bundle our own faster
  alternatives (e.g. our existing `Services.invokeSync` for fetch
  rather than `bare-fetch`'s pure-JS HTTP).
- **Workers spawning workers** — does engine choice propagate, or does
  each `new Worker` re-resolve? Probably re-resolve (each is its own
  decision).
- **Per-engine size budget visible to the user** at build time — print
  "binary +1.4 MB for bare-jsc + fetch + ws" so they see the cost.
