# Display-synchronized window geometry

Status: production controller integrated, 2026-09-11. No Zapp public API changed.
Production now constructs the Z-defined `MacOSWindow` in
`native/z/framework/platform/macos/window-resize.zs`. The compiler gaps recorded
below are resolved; the older sections retain the investigation history.

The controller replaces only native geometry handling. Existing managers,
capabilities, protocol delegates, resize events, and application shutdown stay
in place. It uses a window-associated display link only during an active
animation, preserves immediate sizing, and honors Reduce Motion. Live-resize
and move notifications stop an outstanding transition; fullscreen lifecycle
callbacks hand geometry back to AppKit rather than animating Spaces ourselves.

### Integration evidence

- All 94 modules in Z Notes check through the fixed-point native compiler.
- The production source passes 20 geometry/delegate cases at both `-O0` and
  `-O2` with strict Clang and UBSan: 40 runs, no ASan. These include interrupted
  transitions, stale callbacks, zoom and close vetoes, content constraints and
  delegate standard-frame selection compared with an unmodified `NSWindow`,
  Reduce Motion, cancellation, and system-geometry handoff state without
  replacing the saved user restore frame.
- A real WebView probe at both optimization levels verifies readiness, more
  than three distinct viewport widths, aligned edge layout, resize delegate
  notifications, and return from the AppKit loop after close.
- Both TypeScript check projects and all 502 CLI/runtime tests pass. The
  packaged and dev Z Notes smokes pass with WebView routing, workers, and
  teardown. Dev reports HMR ready and successfully reclaims Vite port 5173.

Run the actual-source harness with
`bun spikes/window-resize/verify-z.ts --run` and `--run --webview`.
`--check` variants never open a window. Every build and child process has a hard
deadline, and timeout cleanup kills its process group. Test-only duration and
accessibility inputs do not modify system settings.

An unchanged AppKit zoom target now remains unchanged: the controller must not
substitute a saved restore frame when a delegate vetoed zoom. That correction
and veto regressions were also carried back to Z's standalone example.

Visual feedback in Z Notes confirmed the resize behavior. The follow-up close
ordering checkpoint below precedes measuring the existing resize event/bridge
path before considering coalescing. Actual mouse dragging during a transition,
fullscreen/Spaces/tiling, screen changes, mixed refresh rates, and physical
accessibility changes still need platform-specific evidence. The handoff tests
are not claims that all those system animations have been validated.

### Accepted close versus shutdown tail

The user observed a pause when closing the last window. The intended contract
is to remove an accepted window promptly, independently of process-wide cleanup;
request vetoes remain authoritative. No new public API or hold mechanism was
introduced.

The actual production controller now calls `super.orderOut(null)` before
`super.close()`, after invalidating its display link. A regression with a
deliberately blocking 250 ms `windowWillClose:` callback failed before the change:
the callback observed `visible=true`. With the change it observes `visible=false`
at both `-O0` and `-O2`. A separate delayed-veto case leaves the window visible
until acceptance. These are native-state assertions, not screen-presentation
measurements, and do not establish that this callback was the cause of the
original user's pause.

Validation after the ordering change: all 40 geometry cases, both real WebView
cases, and all four delayed-close/veto cases pass with strict Clang and UBSan.
Both TypeScript checks and all 502 CLI/runtime tests pass. No ASan was used.

Bounded packaged and dev Z Notes smokes also passed. Observed output intervals
from one run of each (2026-09-11, same workstation):

| Interval | Packaged smoke | Dev smoke |
| --- | ---: | ---: |
| Window-close log to worker-joined log | 18.0 ms | 27.7 ms |
| Worker-joined log to service-stopped log | 0.2 ms | 1.0 ms |
| Service-stopped log to runner exit | 470.6 ms | 831.6 ms |

These are pipe-observation intervals, not per-function profiles. The window log
is a subscribed window's notification, not necessarily the final native window;
runner exit includes launch/runtime teardown and, in dev, Vite cleanup. Thus the
observations do not justify blaming service shutdown for a half-second visible
pause. `spikes/window-resize/trace-shutdown.ts [--dev]` repeats this diagnostic.

Remaining shutdown work is explicitly separate from the accepted-close fix:

1. The single-instance launch listener waits in a socket poll with a one-second
   deadline. Closing its inbox requests cancellation but does not wake that
   wait. Add an explicit cancellation wakeup, including waits on an accepted
   client, instead of reducing the timeout and increasing idle polling. Its
   remaining wait can contribute to process exit, but the trace does not
   attribute the entire measured tail to it.
2. Worker joining still uses synchronous `pthread_join`. Normal cancellation
   was prompt in these runs, but a slow engine teardown can still block the main
   executor. A direct Z `thread.spawn` joining the readonly `ApplicationWorkers`
   owner was rejected by native lowering as a non-shareable ARC capture. Resolve
   the owned cancellation/join seam upstream if needed; do not erase the owner
   into a raw integer or detach cleanup to bypass that protection.
3. The probe also exposed a separate native lowering issue when new delegate
   class fields used defaults: synthesized constructor calls omitted their
   arguments. The fixture supplies explicit fields for now. Retain a focused
   upstream class-default-construction repro before expanding that work.

Wakeup follow-up (2026-09-11): a pipe-backed cancellation prototype is preserved
on local branch `codex/launch-listener-wakeup-prototype`, commit `72e8139`. It is
not merged or claimed working. Its shared owner contains `Mutex<WakePipe>`, whose
custom descriptor cleanup is rejected by Z's cross-thread destruction classifier.
Even an empty custom `deinit` reproduces the restriction. The Z ownership-pressure
log records the pending upstream cleanup-affinity decision. Keep the main branch
working; do not remove the destructor or pass around unowned fds to bypass this
check. Resume the idle/partial-header/partial-body cancellation tests and real
shutdown timing comparison after the ownership contract is agreed and implemented.

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

The user approved the foreign-only `class SmoothWindow extends AppKit.NSWindow
on thread.main` direction, with checked `override`, the existing `as "selector:"`
mapping, and native `super` dispatch. The approved direction and open safety
questions are recorded in Z's `docs/objc-subclass-design.md`. The first field-free
Stage 0 compiler tier now proves native virtual/super dispatch, selector aliases,
base references, designated construction, and exact ARC destruction, and the
actual `NSWindow` declaration passes strict compile-only verification.
This preserves AppKit semantics and keeps production window logic
in Z without introducing ordinary Z-to-Z inheritance.

Construction was approved using `new SmoothWindow(frame)` and an explicit
`constructor` whose first statement is `super.initWithContentRect(...)`. Its
native result is checked, not discarded. Native frontend parity, owned state
lifetime, Ready/main entry checks, and checked selector registration have since
landed upstream. Native callbacks during initialization and teardown must not
observe uninitialized or destroyed Z state. Any new surface must still be
discussed before implementation. The research `.m` stays a test oracle, not a
production backend.

### Historical blockers: real Z subclass probe

Z's `scripts/probe-appkit-subclass-reentry.ts --run` is a bounded, explicit GUI
probe using an actual `NSWindow` subclass written in Z. On the tested Mac:

- A direct animated `setFrame` operation completes.
- An exclusive native entry calling `super.zoom(null)` triggers AppKit's
  virtual `setFrame:display:animate:` callback. The original whole-entry
  `inout this` guard rejected that nested exclusive entry.
- Removing the state writes and making both entries readers permits zoom.
  This is a diagnostic control, not a usable mutable animation controller.

The approved checked superclass handoff now lets the mutable zoom case complete
without changing its receiver capability. All three run at `-O0` and `-O2`
with strict Clang/UBSan and ten-second runtime
deadlines. Expected guard failures are caught to avoid macOS crash reports;
no ASan is used. This measures dispatch compatibility, not WebView presentation
or interrupted-zoom correctness.

These were resolved upstream before integration, without a framework shim:

1. **Implemented upstream:** checked synchronous full-expression `super` calls
   can temporarily release the current receiver loan when their boundary uses
   scalar/enum/plain-record values or literal object `null`. Arguments are
   evaluated first, the receiver remains alive, other readers remain protected,
   and access is reacquired before Z continuation or cleanup. Borrowed arguments
   and nested expressions retain the original guard; live receiver-field loans
   are rejected. This is not a blanket exception around `super`.
2. **Implemented upstream:** `objc.Object` names erased Objective-C identity;
   `zoom:` receives nullable `id`, not an invented `NSObject *` substitute.
3. **Implemented upstream:** synchronous native subclasses compose with
   supported async programs, including Zapp's asynchronous application entry.

The compiler's `docs/objc-subclass-design.md` and `docs/ownership-pressure.md`
record the reproducer and these boundaries. Selector registration support alone
does not mean the full resize integration is ready.

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
