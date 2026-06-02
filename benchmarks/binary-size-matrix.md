# Zapp binary size matrix

macOS arm64 release builds, brotli-compressed assets embedded, no codesigning.
Zapp's webview always works regardless of which row — workers are pure opt-in
cost on top of the webview baseline.

## Results

Measured 2026-06-02. Two reference apps:
- **hello-world** (`hello-world/`) — the canonical small-app shape, single
  zjs ticker worker, supervised demo worker. Webview UI is ~12 KB of brotli
  assets.
- **bench-host-bridge** (`benchmarks/apps/zapp-host-bridge/`) — two-worker
  bench harness, both workers run the same TS source. Used here as the
  per-engine multi-worker size reference.

| Variant | Engines linked | Binary | Δ vs no-workers |
|---|---|---:|---:|
| **no-workers** | (none) | **520 KB** | baseline |
| **hello-world today** | zjs only | **529 KB** | +9 KB |
| **bench (zjs + bare-jsc)** | zjs + bare-jsc | **4.49 MB** | +3.97 MB |
| **bench (zjs + bare-quickjs)** | zjs + bare-quickjs | **5.45 MB** | +4.93 MB |
| **bench (zjs + bare-v8)** | zjs + bare-v8 | **66.55 MB** | +66.03 MB |

Same numbers ranked smallest → largest:

```
no-workers                  ▏ 520 KB
hello-world (zjs)           ▏ 529 KB     +9 KB    (zjs ships ~0 binary overhead — its lib is small)
bench (zjs + bare-jsc)      ▎ 4.49 MB    +3.97 MB (Bare runtime + system JSC binding)
bench (zjs + bare-quickjs)  ▎ 5.45 MB    +4.93 MB (Bare + QuickJS interpreter ~1 MB on top of jsc baseline)
bench (zjs + bare-v8)       █████████████████████████████ 66.55 MB  +66.03 MB
```

## Reading the numbers

**zjs is essentially free.** Adding the first-party `zjs` worker engine
to hello-world adds **9 KB** (529 KB vs 520 KB no-workers baseline). The
zjs static lib is small and ships entirely without bare's NAPI runtime
or libuv. This is the cross-platform default for new projects.

**bare-jsc on top of zjs adds ~4 MB** (bench-host-bridge sits at 4.49 MB
with both engines). Most of that is the Bare runtime + the bundled
bare-* npm modules archive. The Bare ecosystem is the entry point for
`fetch`, `WebSocket`, `fs`, `crypto` workers as à-la-carte capabilities;
the cost is the runtime that hosts those.

**bare-quickjs adds another ~1 MB on top.** QuickJS interpreter (~1 MB)
slots into the Bare runtime that's already there. No JIT. The
recommended pick when you specifically need QuickJS semantics; otherwise
`zjs` is the same-shape small cross-platform engine.

**bare-v8 is the upper bound.** 66 MB. The V8 binary is the engine
itself; V8 ships JIT in exchange for the size. Reach for it only when
worker code is genuinely compute-bound (ML, codec, heavy parsing). Even
then, profile first — typical JS workloads don't bottleneck on
interpreter speed.

## Per-platform defaults

After the kqueue migration (2026-06-01), `zjs` is the documented
cross-platform default on every platform Zapp supports. Per-worker
overrides via `engine: "..."` in `zapp.config.ts` cover the cases where
you want JIT-perf or specific engine semantics.

| Platform | Recommended default | Cost on top of webview-only baseline |
|---|---|---:|
| macOS / iOS / Windows / Linux | **zjs** (free) | +9 KB |
| macOS opt-in for JIT-perf | bare-jsc | +~4 MB |
| Windows / Linux opt-in for JIT-perf | bare-v8 | +~62 MB |
| Specifically needs QuickJS | bare-quickjs | +~5 MB |

## Methodology

Per-engine sizes above come from the `bench-host-bridge` 2-engine
binaries (the CLI can't link more than one bare-* engine at a time
today — see `RESULTS.md` for the constraint). Each row is built by
swapping the `headless` map in `zapp.config.ts` and running
`bun run build && bun run package`.

Pure single-engine binary sizes (zjs-only, bare-jsc-only, etc., without
the second engine in the same binary) are a future measurement pass —
the numbers above are upper bounds, including the constant zjs overhead.
The single-bare-engine numbers will be ~9 KB lower (subtracting the zjs
share).

Run-to-run variance on these size numbers is zero — the same source
produces the same `.text` and `.data` sections deterministically. The
numbers above are reproducible exactly.

## Engines deliberately excluded today

- **bare-mqjs** — vendor/bare's libmqjs cmake step needs an external
  `mqjs-build` tool not shipped with the toolchain. Tracked for upstream
  followup.
- **bare-hermes** — known issue #168 (fetch hangs silently). Bytecode
  pipeline pending the bare-hermes iOS runtime work.

Both can be added back once their respective upstream issues land.

## Caveats

- **Codesigning + entitlements** add ~10-50 KB of Mach-O metadata,
  doesn't move the headline number.
- **Universal binaries** — if you `lipo` x86_64 + arm64 together, expect
  to roughly double the engine-payload portion.
- **iOS adds ~200 KB** of Info.plist + iOS-specific framework refs but
  the engine cost is the same.
