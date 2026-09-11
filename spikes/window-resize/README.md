# Window resize research probe

This directory retains the isolated AppKit/WebKit research oracle (`run.ts`
and `probe.m`) alongside verification of the production Z controller.
The small Objective-C oracle is never linked into the framework, Z Notes, or a
shipped application. It establishes platform behavior independently of the Z
implementation and does not subclass `NSWindow` or use private APIs.

The production Z implementation is now integrated separately. Verify its actual
source (not the Objective-C oracle) from the repository root:

```sh
bun spikes/window-resize/verify-z.ts --check
bun spikes/window-resize/verify-z.ts --check --webview
bun spikes/window-resize/verify-z.ts --run
bun spikes/window-resize/verify-z.ts --run --webview
bun spikes/window-resize/verify-z.ts --run --shutdown
```

This harness needs the sibling Z compiler workspace and its test-only abort
fixture; `ZAPP_Z_COMPILER` can select a rebuilt native driver. It injects only
observation counters and deterministic test inputs into the production Z
controller. The 20 geometry/delegate cases and real WebView check run at `-O0`
and `-O2`, with strict Clang and UBSan. Children have 8-second geometry or
15-second WebView deadlines; timeout cleanup kills the process group. No ASan.
`ZAPP_KEEP_RESIZE_PROBE=1` retains generated source for diagnostics.

`--shutdown` runs two additional close-ordering cases at both optimization
levels. A deliberately blocking 250 ms close notification must observe a hidden
window; a delayed close veto must keep it visible and suppress the notification.
This checks native visibility state, not WindowServer pixel-presentation timing.

To timestamp the real Z Notes shutdown path (one bounded smoke at a time):

```sh
bun spikes/window-resize/trace-shutdown.ts
bun spikes/window-resize/trace-shutdown.ts --dev
```

Accepted windows hide before close notifications and framework shutdown.
The single-instance listener uses an owned cancellation wake pipe, so idle or
partial-client I/O does not hold shutdown until the socket deadline. A packaged
smoke after this change observed 2.4 ms from the close log to worker-join log and
10.1 ms from service-stop log to runner exit (previous observations: 18 ms and
470.6 ms). These are single-run pipe-observation intervals, not pixel timings or
a guarantee about arbitrary application callbacks and cleanup.

The corresponding dev smoke observed 21.5 ms close-log to worker-join and
28.8 ms service-stop to runner-exit, with Vite port 5173 confirmed released
(previous observations: 27.7 ms and 831.6 ms). Build and smoke setup time is not
included in these shutdown intervals.

The trace separates observed window-close, worker-join, service-stop, and runner
exit logs; dev mode also observes Vite port release. Full output and timings are
saved under ignored `.zapp/window-resize/shutdown-*.json`. These are observed pipe
intervals, not per-function profiling: a logged window close is not necessarily
the final native window, and runner exit includes launcher cleanup. The runner
has a four-minute process-group deadline. This does not establish an exit-time
guarantee or measure the moment pixels disappear.

For an interactive application, run `bun run spike:z-notes` and Option-click
the green titlebar button. Close every app window when finished. Automated
geometry checks do not replace visual testing of macOS fullscreen, tiling,
mixed-refresh displays, or dragging during an active transition.

Requires macOS 14+ with a visible, unlocked desktop and Xcode command-line tools.
Run from the repository root:

```sh
bun run spikes/window-resize/run.ts
```

The runner builds an ad-hoc-signed temporary executable with strict warnings and
UBSan (**not ASan**). Each test opens and automatically closes its own window.
The native watchdog is 25 seconds per case; the parent kills the process group
at 30 seconds. Build/sign commands are bounded too. No app identity, service,
worker, Vite process, saved window frame, or developer application is reused.
The executable is removed; raw observation data goes into the ignored
`.zapp/window-resize/` directory, with the exact path printed at completion.

## Resize-event path measurement

```sh
bun spikes/window-resize/measure-events.ts --check
bun spikes/window-resize/measure-events.ts
bun spikes/window-resize/measure-events.ts --allocations
bun spikes/window-resize/measure-events.ts --ubsan
```

The timing, allocation-request, and UBSan passes are deliberately separate.
Each execution runs three automatically closing windows, with a 15-second
process-group deadline per child. `--check` only compiles. No ASan, user app
identity, Vite server, service, worker, or persistent WebView data is used.
The `.zs.in` file is a template, not a standalone Z application.

The probe extracts the production `MacOSWindow`, `Event`, `WindowEvents`, JSON
helpers, and resize delivery function. It bundles the real WebView bootstrap
and public `WindowHandle.subscribe` implementation. A test delegate adds stage
timers; the production window-manager lookup/weak upgrade and application
graph are not included. Animation duration is fixed to 250 ms, with Reduce
Motion disabled **only in the temporary test source**. No system settings change.
It verifies that every native notification reaches both Z listeners and one
frontend listener, with matching ordered window IDs and dimensions. It also
records consecutive duplicate sizes and pending WebKit evaluations.

Reports go to ignored `.zapp/window-resize/events-*.json`, including source
hashes, emitted-code hash, host, optimization/sanitizer mode, and raw payloads.
`allocationCalls` counts instrumented **generated allocation requests**, not
allocator-internal activity or peak memory. Clang can eliminate the backing
storage while preserving the counter (notably the no-listener case). It does
not count framework allocations or retain/release operations. Never treat a
null count as zero, or compare instrumented timings with ordinary timings.

### 2026-09-11 checkpoint

Apple M4 Pro, arm64, Darwin 25.4.0; native Z compiler, Clang `-O2`. Three runs
before and three after transferring the resize payload into its aggregate
event instead of copying it:

| Measured stage | Before: range of run medians | After: range of run medians |
| --- | ---: | ---: |
| Z publication, one specific + one aggregate listener | 1.29–1.38 µs | 1.21–1.38 µs |
| JSON + JavaScript message construction | 2.21–2.42 µs | 2.46–2.54 µs |
| `evaluateJavaScript` enqueue call | 10.63–30.33 µs | 11.04–11.17 µs |
| Enqueue to WebKit completion callback | 0.674–0.800 ms | 0.687–0.747 ms |
| Synchronous frontend dispatch, 10,000-call batch mean | 0.5 µs | 0.5 µs |

These short, non-randomized observations do **not** establish a statistically
significant latency improvement. The concrete reduction is one owned String
copy: generated publication allocation requests go from **2 to 1 per resize**;
serialization remains 11 requests, enqueue adds one generated closure request.
The no-listener path is already near the timer floor after optimization.

The ordinary before/after runs delivered 465/469 events respectively, with no
missing/reordered payloads or consecutive duplicate sizes. Peak outstanding
evaluations were 2 before and 1 after, with complete drainage; these are
observations, not queue-size guarantees. After-change completion p95s ranged
1.32–2.28 ms. Completion includes WebKit scheduling and the return callback,
**not compositor paint or exact one-way IPC latency**. The JS batch excludes IPC
and uses counting-only callbacks, not realistic application handler work.

The frontend performs two JSON parses and one stringify per delivered resize:
one parse for the native data, then a local stringify/parse round trip through
`_onEvent`. That round trip is a future normalization-preserving cleanup, not a
measured bottleneck here. No coalescing, listener filtering, subscription change,
or event loss was introduced. Both Z compilers retain independently copied
payloads after publisher closure at `-O0` and `-O2` under UBSan. Three WebView
UBSan runs verify the final actual-delivery-function instrumentation as well.

Saved version-3 reports: `events-1789167350455.json` (before timing),
`events-1789167370602.json` (before requests), `events-1789167439146.json`
(after timing), `events-1789167458549.json` (after requests), and
`events-1789167635250.json` (final UBSan). Early requestAnimationFrame-gated
probe attempts timed out; readiness now uses a timer and retains hard deadlines.
Those incomplete runs are excluded, not counted as passing observations.

## Visual A/B

Run these separately and repeat as needed:

```sh
bun run spikes/window-resize/run.ts appkit-size
bun run spikes/window-resize/run.ts stepped-size
```

Each grows and shrinks the same responsive page. Watch the bottom-right badge,
card-grid reflow, text, and newly exposed window edges. Does content resize
throughout, or freeze and jump at the end? Does continuous reflow introduce
flicker, gaps, or jitter? These are observation runs, not interactive windows;
manually closing a regular case aborts it and is reported as such.

Compare zoom separately:

```sh
bun run spikes/window-resize/run.ts appkit-zoom
bun run spikes/window-resize/run.ts delegate-zoom
bun run spikes/window-resize/run.ts interrupted-zoom
```

## Further-polish A/B

To compare the current stepped baseline against the three additional variants:

```sh
bun run spikes/window-resize/run.ts compare
```

The order is baseline, background only, frame coordination only, and both.
Each window's title identifies its variant. The page, start/end geometry,
display-link policy, and AppKit animation duration are unchanged. All four
use the same lower-overhead version-2 instrumentation. The runner refuses a
timing comparison if recorded duration, geometry, OS, backing scale, maximum
refresh rate, or Reduce Motion changes between cases.

For visual feedback, the most useful direct pair is:

```sh
bun run spikes/window-resize/run.ts stepped-size
bun run spikes/window-resize/run.ts combined-size
```

If combined looks better, run `background-size` and `coordinated-size` separately
to identify which change helps. In particular, a missing white flash may simply
mean that the native underlay matches the page, not that layout caught up sooner.

For repeated observations with a rotating (not randomized) order:

```sh
bun run spikes/window-resize/run.ts compare --repeat 3
```

Repetition accepts 1–5 rounds and retains the per-process deadlines. The screen
must remain visible and unobstructed. The native sampling code uses a bounded
POD buffer and serializes after the test, avoiding per-display-callback boxed
number/dictionary allocation. It reports dropped samples and rejects overflow.
Do not compare small timing differences against the older, more intrusive
version-1 recorder; the original implementation remains a version-2 control.

## Cases and interpretation

| Case | Experiment |
| --- | --- |
| `appkit-zoom` | Ordinary AppKit zoom/restore. |
| `delegate-zoom` | Intercept `windowShouldZoom:toFrame:`; apply the requested target incrementally and reject AppKit's built-in animation. No independently maintained zoom state. |
| `interrupted-zoom` | Issue a second delegate-intercepted zoom halfway through the first; does it return to the original frame? |
| `appkit-size` | Ordinary `setFrame:display:animate:` to a requested size, then back. |
| `stepped-size` | Apply the same frames using a window-associated display link and AppKit's duration. |
| `background-size` | Baseline stepped frames; set the window background and public WebKit under-page background to the page's unchanged `#15212b`. |
| `coordinated-size` | Pixel-align intermediate frames in backing coordinates, skip unchanged frames, set `display:NO` within an explicit transaction with implicit actions disabled. No forced flush, webpage pre-layout, or new interpolation curve. |
| `combined-size` | Background matching plus frame coordination. |
| `retarget-size` | Replace an in-flight size target with the original frame, starting from the current geometry. |
| `close-size` | Close halfway through; invalidate the display link and check no further callbacks arrive. |

Normal size changes assert exact requested/restored geometry within one point.
The two delegate-zoom cases report restoration but deliberately do not require
it: they are feasibility experiments, and the interrupted case currently
demonstrates a failure. A green runner does **not** mean every candidate works.
All cases require WebView readiness, stopped animations, invalidated timers,
and no post-close display callback.

The native observer samples `WKWebView.bounds` at display callbacks and resize
notifications. The page reports `innerWidth`/`innerHeight` from
`requestAnimationFrame` when dimensions change, plus an occasional heartbeat.
Printed counts are **distinct observed sizes**, not rendered frames or FPS.
Message receipt times include WebKit process/IPC scheduling; do not interpret
them as compositor presentation timestamps or exact input latency. The probe
has no Zapp JSON/event delivery path, so its overhead is not a Zapp benchmark.
Its continuously running display observer is instrumentation, not a proposed
always-on framework animation loop.

`observed width gap p95` is the absolute difference between native width and
the latest **received** DOM width, sampled at display callbacks within the
requested animation interval. It includes WebKit message transit and is neither
a measured blank-strip width nor a paint-latency measurement. When AppKit's
animation prevents the observer from seeing moving frames, it reports `n/a`,
not zero lag. Page-clock
intervals between changed DOM dimensions are retained for analysis, but these
too are layout observations, not compositor presentation. Native writes and
skipped writes are per transition, not cumulative. Slowing the animation is not
an optimization in this comparison.

Validate the metric calculations without opening windows:

```sh
bun test spikes/window-resize/metrics.test.ts
```

System Reduce Motion is honored and recorded. With it enabled, expect direct
changes, not evidence about animation smoothness. No system setting is modified.
Fullscreen/Spaces, OS tiling, live mouse resizing, multiple screens, refresh-rate
changes, and heavy production pages remain separate tests.

See [engineering plan](../../docs/plans/window-resize-polish.md) for evidence,
the native zoom-state limitation, and the pending implementation decision.
