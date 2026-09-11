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
