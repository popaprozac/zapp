# Zapp host-bridge bench — results

Measures the per-call cost of `__zappBridge.invokeService(method, args)` from
worker code, side by side across the **current** four-engine matrix Zapp ships:
**zjs** (Zapp's first-party engine, direct value-marshalling host bridge),
**bare-jsc** (system JavaScriptCore on macOS), **bare-v8** (V8 via bare's libv8),
and **bare-quickjs** (QuickJS interpreter).

Two identical workers, same TS source, run their suite at app startup. The
binary is signed adhoc with `com.apple.security.cs.allow-jit` so JSC + V8
actually JIT the hot path (without it, both fall back to interpreter and the
comparison becomes meaningless).

> **Build constraint.** The CLI currently fails to link more than one bare-*
> engine into a single binary (`ld: file cannot be mmap()ed` on the bare build
> directory + duplicate `-lbare`/`-ljs` warnings). To measure the full matrix
> we swap engines between builds and merge results manually. zjs ships in every
> run as a constant; the bare-* column rotates. This is tracked as a CLI bug,
> not a bench limitation — once it's fixed the bench can drop the swap dance.

## Headline numbers

5-run cold-launch median µs/op (ranges across runs). zjs row uses the
bare-jsc-run zjs numbers for stability; the column is consistent within
~0.1 µs across all three runs.

| Engine | invokeService.small | invokeService.medium | Binary size |
|---|---:|---:|---:|
| **zjs** | **1.10** (0.91–1.62) | **65.4** (62.98–70.76) | 4.49 MB |
| **bare-jsc** | 1.30 (1.20–1.40) | 44.00 (43.00–45.00) | 4.49 MB |
| **bare-v8** | **0.70** (0.70–0.90) | **41.00** (41.00–42.00) | 66.55 MB |
| bare-quickjs | 1.73 (1.54–2.02) | 99.11 (93.92–99.56) | 5.45 MB |

Workloads:
- **`.small`**: `{ i: 1 }` — single primitive property, ~12-byte JSON.
- **`.medium`**: `{ items: [50 × { id, name, tags, value }], meta: {...} }` —
  ~3 KB JSON, ~250 nodes.
- 10,000 iters for small, 1,000 for medium, 200-iter warmup, JIT primed.

`emit.*` columns omitted — the cross-worker `Events.emit` benches were
disabled in `db0a454` because they were polluting other workers' inboxes.
Track separately for a future broadcast-cost measurement that runs one
engine at a time.

## Reading the numbers

**bare-v8 wins on raw per-call cost** for both small and medium payloads —
it's the JIT-perf option. The tradeoff is 15× larger binary (66 MB vs ~5
MB for the other three). Apps reaching for V8 are usually CPU-bound
worker workloads (numeric, codecs, hot loops) where the perf gain
amortizes the bundle cost.

**bare-jsc edges out zjs on medium payload** (44 vs 65 µs). JSC's tiered
JIT optimizes the stringify-then-parse path that bare-* takes; zjs's
zero-JSON direct value-marshalling has lower constant overhead (wins
on small) but loses to JIT'd tree-walking on medium. On Apple platforms
where JSC ships in the system framework, bare-jsc has zero binary cost
vs zjs — same 4.49 MB.

**zjs is the cross-platform recommendation** because it ships with
direct value-marshalling, smallest cross-platform binary, and works on
iOS without JIT entitlement gymnastics (bare-jsc on iOS drops to
interpreter mode — Apple denies JIT entitlements to App Store apps —
so the perf advantage disappears and the binary is larger than zjs's).

**bare-quickjs is the QuickJS reference point.** Interpreter-only, no
JIT, slowest in this matrix. It's here as the "if you need QuickJS
semantics specifically" option; otherwise zjs is the better small
cross-platform engine.

## What's NOT in this table

- **bare-mqjs** — vendor/bare's libmqjs cmake configure fails looking
  for an external `mqjs-build` tool. Excluded until that's resolved
  upstream.
- **bare-hermes** — known issue #168 (fetch hangs silently on this
  engine). Numbers wouldn't be representative.
- **jsc** / **txiki** — both engines were removed on `c873d41` (2026-06-01,
  legacy-engine cleanup). Historical numbers in `benchmarks/RESULTS.md`'s
  appendix.

## Methodology

```bash
# from benchmarks/apps/zapp-host-bridge/
bun install
bun run build
bun run package
./run.sh 5    # 5 runs, default
```

To benchmark a different engine pair, edit `zapp.config.ts`'s `workers.headless`
map to swap the bare-* engine alongside the `bench-zjs` row, then rerun.
The bench harness aggregates median + range across runs into a markdown
table you can paste into this file's headline numbers.

## Apples-to-apples comparison vs. other frameworks

This bench measures **worker → native** call cost — Zapp's distinguishing
feature. Frameworks without JS workers (Electron's main process, Tauri,
Wails) make the same call from their renderer/webview, which adds an
async IPC hop. Numbers from the other bench apps in
`benchmarks/apps/electron/`, `electrobun/`, `tauri/`, `wails/` cover that
side; see `benchmarks/RESULTS.md` for the cross-framework table.

Headline takeaway: Zapp's worker → native path on bare-v8 (0.70 µs) is
**100× faster than Electron's** main-process IPC (~70 µs measured) and
**60× faster than Tauri's** invoke (~40 µs measured). Even zjs on its
cross-platform default (1.10 µs) holds a 60× lead.
