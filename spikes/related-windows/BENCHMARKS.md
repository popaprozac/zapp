# Related-window performance: first look

Measured 2026-09-12 on macOS 26.4 (25E5223i), Apple Silicon, system WKWebView.
React / React DOM 19.2.0 production build; Bun 1.3.14; Apple Clang 17.0.0.
Native harness compiled with `-O2 -DNDEBUG`, ARC, strict warnings, no sanitizer.

This is an independent platform experiment, not a benchmark of the full Zapp
framework or of Z compilation. It was first run outside the repositories and is
now retained here as a research oracle; no production framework API is added.

## Outcome

Related windows avoid the native JSON relay for shared frontend updates. In
this small workload, update-and-confirm completion was approximately 5.4–5.5x
faster with an owner-driven portal. The absolute saving was about 0.19 ms per
update, not a 5x improvement in frame rate.

Later child openings reached populated content plus two child animation-frame
callbacks in about 57 ms, versus 89–90 ms for independent windows. However, a
related child loading its own React root was equally quick to open. Therefore
we cannot attribute most of this startup difference to framework reuse.

## Three controlled variants

| Variant | Native creation | Child JavaScript | State delivery |
|---|---|---|---|
| Related portal | `window.open`, supplied WKWebView configuration | 265-byte helper; owner React root renders portal | Direct owner update and child DOM assertion |
| Related separate root | Same related `window.open` route | Full React bundle and its own root | Direct function call and acknowledgement through opener |
| Independent separate root | Fresh WKWebView configuration | Full React bundle and its own root | JSON through WKScriptMessageHandler, native forwarding, evaluateJavaScript, and acknowledgement |

All children show the same 128-row document inspector. Updates change its
selected row, title, and sequence, alongside the owner's sequence. Assertions
verify owner and child committed DOM values. Both separate-root variants use
the same child page and production bundle.

## Custom-protocol results

These use `zapp://probe`, making them relevant to a future bundled-asset path.

| Metric | Related portal | Related separate root | Independent separate root |
|---|---:|---:|---:|
| First child: populated + two rAF callbacks, median | 93 ms | 93 ms | 106 ms |
| Later children: populated + two rAF callbacks, median | 57 ms | 56 ms | 89 ms |
| Update-and-confirm: median of per-run amortized means | 0.043 ms | 0.046 ms | 0.234 ms |
| 32 logical changes coalesced into one commit: same statistic | 0.030 ms | 0.030 ms | 0.210 ms |
| Update + two child rAF callbacks, median | 33 ms | 33 ms | 33 ms |
| Child script load/init marker, median | <1 ms resolution | 1 ms | 4 ms |

The related separate-root first-child measurements include a 332 ms outlier.
With only five runs per group, tail values are exploratory, not robust p95
service-level measurements. Complete samples are retained.

## HTTP-loopback control

| Metric | Related portal | Related separate root | Independent separate root |
|---|---:|---:|---:|
| First child: populated + two rAF callbacks, median | 91 ms | 89 ms | 94 ms |
| Later children: populated + two rAF callbacks, median | 57 ms | 57 ms | 90 ms |
| Update-and-confirm: median of per-run amortized means | 0.043 ms | 0.047 ms | 0.238 ms |
| 32 logical changes coalesced into one commit: same statistic | 0.030 ms | 0.030 ms | 0.210 ms |
| Update + two child rAF callbacks, median | 33 ms | 33 ms | 33 ms |
| Child script load/init marker, median | <1 ms resolution | 1 ms | 4 ms |

## Does reusing the owner's framework accelerate child startup?

It avoids loading/evaluating a second framework instance, creating another root,
and independently bootstrapping app state, routes, or providers. This probe's
portal child runs only a 265-byte helper instead of the 197,022-byte production
React/application bundle. These are uncompressed script sizes, not measured
network transfers, binary-size reductions, or memory savings.

But native window creation, a new document, DOM construction, CSS, layout, and
compositing still happen. The control above shows no convincing additional
startup win from portal reuse over a related separate root for this lightweight
app. Browser relationship/setup and caching are possible contributors to the
independent-window difference; we did not isolate their individual costs or
measure renderer process identities.

A larger real application may save more bootstrap work, but that remains a
hypothesis. A good next benchmark would use the same representative app in both
models, report cold and warm startup separately, and measure process-family
memory and actual presentation timing.

## Method and limits

- Five rounds x two origins x three variants: 30 successful native processes.
  Variant/origin order rotates. Every run creates and closes four child windows:
  120 opens and 120 close callbacks, with zero failures and empty native stderr.
- The owner is already loaded before timing child creation. First child does
  not mean cold application startup. OS/code/resource caches are uncontrolled;
  HTTP caching is allowed. These are local assets, not remote network loads.
- Each process measures 1,000 sequential updates, 300 coalesced commits, and 24
  frame-paced samples, after 20 warmups per category. Totals: 30,000 updates,
  9,000 coalesced commits, and 720 frame-paced samples, excluding warmups.
- All variants force React commits with `flushSync`. This isolates a repeatable
  commit workload; it is not normal React concurrent scheduling or real input.
- The independent path includes serialization, native forwarding, rendering,
  and an acknowledgement return trip. It measures observable completion, not
  pure transport latency or the minimum one-way time to a visible update.
- JavaScript timer readings showed roughly 1 ms quantization. Individual
  micro-samples often read zero. The reported sub-millisecond numbers divide
  whole-loop wall time by the sample count, then take the median across runs.
  A zero sample is never interpreted as zero cost.
- Two child `requestAnimationFrame` callbacks are only a frame-scheduling proxy,
  not physical pixel presentation or input-to-photon latency. Their similar
  results do not establish equal frame rate under heavier workloads.
- Startup separate-root cases include an additional initial-state publish/ack;
  portal startup mounts its portal directly. This is an end-to-end shape
  comparison, not an exact decomposition of framework initialization cost.
- Native construction timers cover WKWebView creation and window hosting only;
  they omit configuration creation and asynchronous loading. Raw values are
  available, but should not be subtracted from JS totals as a causal breakdown.
- No memory, energy, CPU utilization, allocation, leak, crash-isolation, or
  cross-platform conclusions. No full Zapp permission/service overhead is in
  this minimal relay. This is not a comparison against Wails, Tauri, or Electron.

## Architectural takeaway

There is evidence to keep exploring an optional related-window family: direct
frontend coordination is materially cheaper in this probe, and one framework
owner can naturally drive several native window documents. That benefit comes
with shared trust, scheduling and owner-lifecycle coupling. Independent windows
remain useful for isolation and independently heavy UI work. These measurements
do not select a public API or weaken Zapp's capability model.

## Reproduce and inspect

```sh
cd spikes/related-windows
bun install --frozen-lockfile --ignore-scripts
bun run benchmark
```

This briefly opens native windows. Each native process has an internal
30-second deadline and an external 35-second process-group deadline. Compilation
has a 30-second deadline. The ephemeral loopback server stops in `finally`.
The runner preserves an existing raw result under a timestamped backup name.

- `results/2026-09-12/benchmark-summary.json`: six five-run groups and summary statistics.
- `results/2026-09-12/benchmark-raw.json`: all raw timings, assertions' successful completion,
  stderr, native child counts, and relay counts.
- `benchmark.ts`: bounded runner, production bundling, and aggregation.
- `benchmark.m`: isolated AppKit/WebKit host and native relay.
- `bench.jsx`: identical UI workload and three delivery paths.

New runs write ignored `.artifacts/benchmark-results.json` and
`.artifacts/benchmark-summary.json`, never overwrite the dated evidence, and
leave generated binaries/bundles ignored. The recorded baseline was measured
in the temporary directory before retention here; runner typing, output paths,
and argument validation were subsequently adjusted without changing the
benchmark workload or native host. See [README.md](README.md) for feasibility
coverage and [the experiment plan](../../docs/experiments/related-windows.md)
for design and integration gates.
