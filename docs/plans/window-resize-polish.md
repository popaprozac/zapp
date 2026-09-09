# Display-synchronized window geometry

Status: platform probe, 2026-09-09. No Zapp public API or Z syntax changed.

## Agreed intent

Improve native-feeling window resizing by keeping the WebView viewport updated
through the transition. Start with zoom/restore; if successful, reuse the
foundation for other animated window size changes rather than shipping a
zoom-only special case. This does **not** mean adding an animation to every
resize: immediate changes and direct mouse tracking must remain immediate,
and system-owned fullscreen/tiling behavior must not be overridden blindly.
Honor Reduce Motion. Prefer an internal default behavior, not a new application
configuration switch, unless evidence establishes a genuine user choice.

Wails provides useful implementation references:

- [#5856](https://github.com/wailsapp/wails/pull/5856): AppKit chooses zoom targets;
  intermediate nonanimated frames keep WKWebView from deferring viewport updates.
- [#5900](https://github.com/wailsapp/wails/pull/5900): preserve the user restore
  frame, including interrupted animation and titlebar drag interactions.
- [#5945](https://github.com/wailsapp/wails/pull/5945): window-associated
  CADisplayLink on macOS 14+, display-rate-aware fallback, timestamp interpolation.

Do not copy only the smooth-animation part while losing native window state,
delegate hooks, constraints, cancellation, or accessibility behavior.

## Reproducible evidence

[The probe](../../spikes/window-resize/README.md) creates an ordinary NSWindow
and WKWebView in an isolated native executable. It compares unmodified AppKit,
delegate-only interception, and display-driven arbitrary frame transitions.
This Objective-C test oracle is not a framework shim or a production dependency.

Observed on macOS 26.4 (25E5223i), screen maximum 120 Hz, Reduce Motion off:

| Case | Distinct native / DOM sizes, grow; restore | Geometry result |
| --- | --- | --- |
| AppKit zoom | 42 / 2; 41 / 1 | Restored original frame. |
| Delegate-only incremental zoom | 39 / 21; 40 / 20 | Ordinary restore worked. |
| Interrupted delegate zoom | 57 / 29 | **Did not restore**: two rapid requests ended enlarged. |
| AppKit requested size | 41 / 2; 41 / 1 | Restored original frame. |
| Display-driven requested size | 39 / 20; 39 / 20 | Reached requested frame and restored. |
| Retarget requested size | 53 / 29 | Returned to original frame from a partial transition. |
| Close during transition | 20 / 11 | Closed; no subsequent display callbacks. |

One initial run timed out before WebView readiness; it is not animation
evidence. The completed matrix uses a nonpersistent WebKit data store, explicit
DOM element references, page/navigation error reporting, bounded readiness,
and cleanup. Raw observations are emitted to ignored `.zapp/window-resize/`.

Counts are observations of viewport/layout dimensions, **not presentation FPS**.
The display's 120 Hz maximum does not imply that WebKit painted at 120 Hz.
The native clock measures receipt of DOM messages, not the compositor. This
single-machine evidence supports further work; visual A/B feedback and more
display/OS cases remain necessary.

A second complete seven-case run reproduced the distinction (1–2 DOM sizes
for ordinary AppKit transitions, 20–21 for the completed display-driven size
transitions) and the interrupted-zoom failure. The final harness checks invalidated
timers and zero post-close callbacks as well as final geometry. Strict Clang
warnings, UBSan, both TypeScript check projects, and all 502 CLI/runtime tests
pass. No resize-probe process remained after the runs. These are probe results,
not a claim that Zapp already implements smooth resizing.

## Implementation boundary to deliberate

The probe establishes that display-driven transitions help beyond zoom. It
also establishes that naive delegate interception is insufficient: during a
partially completed zoom, the next native request still targets the enlarged
frame. Do not infer that all composition-based designs are impossible, but do
not ship this candidate as correct.

Wails solves the state problem in an NSWindow subclass by overriding `zoom:`,
`isZoomed`, `animationResizeTime:`, both `setFrame` variants, and close/cleanup.
It can synchronize the old intended state before calling the superclass and
keep exact restoration semantics. Z's current `objc.adapt<P>` generates an
NSObject protocol adapter; that does not supply native superclass overrides
or `super` dispatch.

Next design checkpoint: compare a narrowly checked native-subclass/override
interop facility with a fully specified composition approach that independently
owns zoom state. Prefer preserving AppKit semantics and keeping Zapp logic in Z.
Any new Z API/syntax must be discussed with the user before implementation.
Do not quietly turn the research `.m` into a production backend or introduce
general Z inheritance to solve this one foreign-interface requirement.

## Follow-through after that decision

1. Implement a Z-owned frame-transition state machine reusable for zoom and
   other requested animated size changes. A new target starts at current
   geometry; the previous transition stops writing. No permanent idle ticker.
2. Preserve AppKit zoom/restore state, delegate constraints, and interruptions.
3. Test close, shutdown, callback ownership, and accessibility; add exact
   deterministic geometry tests separately from visual pacing observations.
4. Measure Zapp's `windowDidResize` path: it currently emits an encoded event
   through `evaluateJavaScript` for each notification. Avoid avoidable bridge
   work, but deliberate event coalescing semantics before changing delivery.
5. Integrate a visible Z Notes demonstration and collect user A/B feedback.
6. Expand deliberately to other size changes: programmatic transitions first;
   live mouse resize, fullscreen/Spaces, tiling, screen transitions, and varied
   refresh rates each need their own native-behavior and cancellation tests.

This work does not require a new public `Window` animation API yet. The existing
Z readonly-alias/index interpolation follow-up remains separately recorded in
Z's ownership-pressure log; it does not block this probe or design checkpoint.
