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

## Second polish pass: separate work, latency, and appearance

The user visually confirmed that stepped sizing is much cleaner, particularly
while growing, but still exposes some white background. The next agreed probe
compares four variants with the same page, geometry, interpolation, requested
350 ms duration, and display-link policy:

1. Unchanged stepped-frame algorithm (control).
2. Match native/window WebKit underlay to the page (visual control only).
3. Pixel-align intermediate frames; skip unchanged geometry; apply `display:NO`
   inside a scoped Core Animation transaction with implicit actions disabled.
4. Combine background and coordination changes.

No private WebKit APIs, forced synchronous flushes, extra viewport area,
snapshots, or JavaScript acknowledgement-driven pacing were introduced. Public
[`underPageBackgroundColor`](https://developer.apple.com/documentation/webkit/wkwebview/underpagebackgroundcolor)
is a style control, not a renderer synchronization mechanism. Speculative
pre-rendering remains deferred because it can change responsive breakpoints,
positioned elements, hit testing, and memory use.

All candidates now use version-2 bounded POD sample capture with end-of-run
serialization instead of allocating boxed native samples on every display
callback. The runner compares conditions and rotates the starting candidate
across repeated rounds. Measurements from the old recorder are not suitable
for small-difference comparisons against the new one.

Three rounds on the same macOS 26.4/120 Hz-maximum display, Reduce Motion off
(six transitions per variant, all 350 ms):

| Variant | Observed DOM sizes per transition | Native frame writes | Skipped writes | Observed width-gap p95 range |
| --- | --- | --- | --- | --- |
| Stepped control | 20–21 | 42–43 | 0 | 76–84 pt |
| Background only | 20–21 | 42–43 | 0 | 76–82 pt |
| Coordination only | 21 | 38–40 | 3–5 | 76–81 pt |
| Combined | 20–21 | 38–40 | 3–5 | 77–84 pt |

All requested endpoints/restores and cleanup assertions passed. Page-clock
intervals between changed DOM dimensions were typically about 17 ms in these
observations. Neither that nor the screen's maximum rate establishes paint FPS.
The width-gap statistic compares current native geometry with the latest received
DOM dimensions during the requested animation interval; it includes message
transit and cannot measure blank pixels or exact presentation lag.

The subsequent full-matrix validation also observed larger gaps under the same
requested geometry (for example 121–125 pt for the stepped control). This
reinforces the sensitivity to run-loop/IPC scheduling and uncontrolled system
load: the table is one recorded comparison session, not a stable platform
latency bound. AppKit's built-in animation can prevent display-observer samples
throughout the transition; that case now reports unavailable gap evidence
rather than misleadingly printing zero.

Conclusion: the candidate avoids several redundant native writes, but there is
**no demonstrated substantial viewport-latency improvement** beyond the original
stepped algorithm. These small overlapping ranges are not a CPU, energy, or
paint-performance win. Keep the simpler original as the reference; do not
promote extra transaction machinery purely because it looks more sophisticated.

The subsequent user visual comparison found no large difference between these
variants. White background remained visible during zoom; the meaningful win was
the responsive viewport throughout resizing. This closes the second polish
probe: retain the original stepped approach as the implementation baseline.
Consistent native/page backgrounds remain separate cosmetic polish, not evidence
of reduced rendering lag. Do not extend the coordination experiment without new
evidence that justifies it.

The next work is correctness and the native override design checkpoint above,
not another rendering experiment. Current Z protocol adapters own a separate Z
controller and generate an `NSObject<Protocol>` object; changing that object's
base alone would not provide a sound subclass implementation. Native receiver
identity, superclass dispatch, construction-time callbacks, ARC cleanup, and
executor provenance need explicit treatment. A foreign-subclass proposal is not
approval for general inheritance among ordinary Z classes. Deliberate the new
declaration/method surface before implementing it, then settle initialization
and state lifetime before attempting a stateful production window subclass.

Run `bun run spikes/window-resize/run.ts compare` for visual feedback, or
`compare --repeat 3` for repeated observation data. The original interrupted
zoom-state issue remains unchanged and still blocks production adoption of the
delegate-only zoom candidate. No Zapp application-facing API or Z syntax changed.

Validation: the expanded ten-case native matrix and a final four-way comparison
pass strict Clang/UBSan, exact endpoint and cleanup checks. Eight focused metric
tests, both TypeScript projects, and all 502 CLI/runtime tests pass. The unit
tests explicitly cover missing observations so unavailable timing evidence does
not become a claimed zero-lag result. No ASan was used.
