# Window resize research probe

This is an isolated AppKit/WebKit experiment, **not an implemented Zapp feature**.
It is never linked into the framework, Z Notes, or a shipped application.
The small Objective-C oracle establishes platform behavior before choosing a
Z implementation or adding language capabilities. It does not subclass
`NSWindow` or use private APIs.

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

## Cases and interpretation

| Case | Experiment |
| --- | --- |
| `appkit-zoom` | Ordinary AppKit zoom/restore. |
| `delegate-zoom` | Intercept `windowShouldZoom:toFrame:`; apply the requested target incrementally and reject AppKit's built-in animation. No independently maintained zoom state. |
| `interrupted-zoom` | Issue a second delegate-intercepted zoom halfway through the first; does it return to the original frame? |
| `appkit-size` | Ordinary `setFrame:display:animate:` to a requested size, then back. |
| `stepped-size` | Apply the same frames using a window-associated display link and AppKit's duration. |
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

System Reduce Motion is honored and recorded. With it enabled, expect direct
changes, not evidence about animation smoothness. No system setting is modified.
Fullscreen/Spaces, OS tiling, live mouse resizing, multiple screens, refresh-rate
changes, and heavy production pages remain separate tests.

See [engineering plan](../../docs/plans/window-resize-polish.md) for evidence,
the native zoom-state limitation, and the pending implementation decision.
