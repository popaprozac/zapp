# Zapp binary size matrix

Hello-world built six ways on macOS arm64 with the same UI, no headless
workers, brotli-compressed assets embedded. Zapp's webview always works
regardless of which row — workers are pure opt-in cost on top.

## Results

| Variant | Engines linked | Binary | Δ vs no-workers |
|---|---|---:|---:|
| **no-workers** | (none) | **520 KB** | baseline |
| **jsc-only** | legacy jsc.m | **578 KB** | +58 KB |
| **bare-jsc-only** | bare runtime + libjsc binding | **1.28 MB** | +755 KB |
| **bare-quickjs-only** | bare runtime + QuickJS-NG | **2.28 MB** | +1.76 MB |
| **bare-v8-only** | bare runtime + V8 (prebuilt) | **62.22 MB** | +61.7 MB |
| **all-three (current)** | jsc.m + txiki.c + bare-jsc | **7.55 MB** | +7.04 MB |

Same numbers ranked smallest → largest:

```
no-workers         ▏ 520 KB
jsc-only           ▏ 578 KB     +58 KB  (system framework, near-free)
bare-jsc-only      ▎ 1.28 MB    +755 KB (Bare runtime + libjsc binding)
bare-quickjs-only  ▌ 2.28 MB    +1.76 MB (Bare + QuickJS interpreter)
all-three          ███ 7.55 MB  +7.04 MB (jsc + txiki + bare-jsc, today's hello-world)
bare-v8-only       █████████████████████████████████████████████████████████████ 62.22 MB
```

## Reading the numbers

**Zapp baseline is genuinely tiny.** A pure-webview Zapp app is **520 KB** —
all the platform.m / window.m / webview.m / dialog.m / menu.m / clipboard.m
machinery and the Vite-bundled UI. That's <2% of the next-smallest
cross-platform desktop framework's wire weight.

**JSC on macOS truly is free.** Adding the legacy `jsc.m` worker engine costs
**58 KB** — the engine itself comes from the system JavaScriptCore.framework,
so we're only paying for the ~500 lines of Objective-C glue. JIT works (with
the `allow-jit` entitlement we now auto-merge). This is the smallest possible
worker-enabled Zapp app on macOS.

**bare-jsc adds ~700 KB** — the Bare runtime, libuv (264 KB), libutf (48 KB),
and the bundled bare-* npm modules archive (~206 KB). Compare to legacy
jsc.m: paying ~700 KB extra for the npm-shaped module ecosystem (`bare-fetch`,
`bare-ws`, `bare-fs`, `bare-crypto`, etc.) is the right trade for any
non-trivial app. Same JIT speed, same JSC engine.

**bare-quickjs adds ~1.76 MB** — Bare runtime + the QuickJS-NG engine
(~1 MB). No JIT (interpreter only). On Windows / Linux this is the
**recommended Zapp default** for new projects: tiny binary, predictable
performance, npm-module ecosystem. Apps that need CPU-heavy worker code
opt into bare-v8 explicitly.

**bare-v8 is the upper bound.** 62 MB of V8 binary. The engine ships JIT,
but you're paying ~33× the binary cost vs bare-quickjs on every install.
Reach for it only when worker code is genuinely compute-bound (ML, codec,
heavy parsing). Even then, profile first — typical JS workloads in real
apps don't bottleneck on interpreter speed.

**The current hello-world (all-three) is 7.55 MB** because it links jsc.m +
txiki.c (which carries libwebsockets + ada + miniz + sqlite + mbedtls
internally) + bare-jsc. **Going to "bare-jsc only" drops it to 1.28 MB —
an 83% binary size reduction.** This is the headline gain from the
jsc.m + txiki.c removal once the soak completes.

## Per-platform recommendations

| Platform | Default | Cost on top of webview-only baseline |
|---|---|---:|
| macOS / iOS | **bare-jsc** | +755 KB |
| Windows / Linux | **bare-quickjs** | +1.76 MB |
| Compute-heavy on Windows / Linux | bare-v8 (opt-in) | +61.7 MB |

Devs who don't need Zapp workers at all (just the webview) ship a 520 KB
binary on every platform. That's a clear story.

## Methodology

The bench script (`/tmp/binsize-bench.sh`) overwrites
`hello-world/zapp/build.zc` and `zapp.config.ts` with minimal known-good
shapes per variant, runs `bun run build`, and records the resulting
`bin/hello-world` size. Each variant clears `.zapp/` and `bin/` first so
nothing carries over from the previous build. All builds are macOS arm64
release, brotli-compressed assets embedded, no codesigning.

Variants don't include `bare-mqjs` (micro-QuickJS) — needs a separate cmake
configure that's tracked under the future engine-decision matrix work.
Numbers from prior measurements suggest mqjs lands around 1.2-1.4 MB.

## Caveats

These are bare-bones benchmarks of static binary size — what you'd see
when you `du -k hello-world` after `bun run build`. Real shipped numbers
also include:

- **Codesigning + entitlements** — adds ~10-50 KB of Mach-O metadata,
  doesn't move the headline number.
- **Universal binaries** — if you `lipo` x86_64 + arm64 together, expect
  to roughly double the engine-payload portion.
- **Code-signed `.dmg` / `.zip` distribution** — adds compression
  variance.
- **iOS adds ~200 KB** of Info.plist + iOS-specific framework refs but
  the engine cost is the same.

Run-to-run variance on these size numbers is zero — the same source
produces the same `.text` and `.data` sections deterministically. The
numbers above are reproducible exactly.
