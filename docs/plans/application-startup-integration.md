# Application startup integration checkpoint

Automatic forwarding is now wired into macOS `Application.run()` when the
existing `application.singleInstance` setting is true. The saved draft has been
applied and its obsolete patch removed. The disabled path creates no listener,
readiness channel, or delivery scope.

## Verified

- Listener shutdown now closes admission and signals an owned, sticky wake
  pipe before joining the worker. Accept and partial-frame I/O poll that pipe
  alongside the socket. Cancellation never closes an active socket from a
  different thread and does not increase idle polling frequency.
- The wake pipe is a move-only Z resource with checked `deinit on thread.any`,
  retained inside a readonly owner through `Mutex<LaunchWakePipe>`. The lock is
  released before I/O waits; final ownership closes both pipe ends exactly once.
- `ZAPP_LAUNCH_UBSAN=1 bun cli/src/test-launch-startup-macos.ts` passes on both
  compilers for normal delivery, idle, partial header/body, repeated/full-pipe
  cancellation, simultaneous readiness, and startup failure. This run observed
  cancellation-to-join below 3 ms. The test threshold is a generous 400 ms to
  detect regression to the former one-second socket timeout, not a latency SLA.
- The production-shaped listener owns its endpoint and election lease on one
  native worker. A capacity-one Channel reports primary readiness, completed
  secondary forwarding, or a typed failure before AppKit setup.
- `launch-delivery.zs` holds a separate main-bound event owner until listener
  cancellation/join and every admitted main-executor wake have completed.
- Both the Stage 0 and fixed-point native UBSan matrices pass real
  primary/secondary processes, idle cancellation, a partial native request during
  shutdown, and a hostile socket path during startup. They check one delivery,
  arguments/cwd snapshots, ordered joins, lease reacquisition, and socket cleanup.
- The complete native Application.run gate passes endpoint setup failure,
  service-startup failure, and real primary/secondary processes. A secondary
  forwards its empty/spaced/Unicode arguments and cwd exactly once, exits zero,
  and creates neither an AppKit application nor started services. Both failures
  return typed errors, reach stopped state, and release the same identity for
  the next launch. The hostile socket symlink is preserved.
- With the wrapper applied and single-instance disabled, the full native Z
  Notes auto-closing smoke passes with an isolated application identity:
  WebView/service round trips,
  application-worker messages, cancellation/join, and service teardown remain
  working. Both TypeScript check projects also pass.
- Generated metadata now exposes the existing `application.singleInstance`
  setting as a private build hook, default false. No new configuration key was
  introduced. Application.run now uses this hook before native host startup.

The full gate is `bun cli/src/test-application-startup-macos.ts`. Its build has a
240-second deadline; each launched process has a 15-second deadline and tree
cleanup. It uses a random identity and a signed private smoke bundle, never the
interactive Notes bundle or its LaunchServices registration.

The first full run found a test-source ownership error that native Z incorrectly
accepted: extracting `app.context.arguments` shallow-copied readonly owned
storage. Stage 0 rejected it. Native cleanup/ownership classification is now
fixed upstream, with rejection parity and a valid read/copy/await UBSan probe.
The application fixture reads the array in place and copies only its mode
string. Service-startup rollback and process teardown now both exit cleanly.

## Historical upstream checkpoints

These entries record the state at each earlier checkpoint. References below to
an unapplied wrapper describe those earlier states, not the current integration.

The imported internal async-call identity blocker is fixed upstream. Lowering
preserves each direct call's source site and resolves its final emitted name
using checked target module/symbol evidence. Native-header builds, renamed
imports, same-named internal functions, same-module calls, and generic
specializations are covered. The production listener now executes natively.

Early awaited returns now compose with one later awaited local in native
function and supported method frames. Both branches, owned results/failures,
root-local cleanup, and 72 cold-drop/cancellation/destruction cases pass under
UBSan. The compiler reaches a fixed point, and all eight production-shaped
startup process cases pass again with Stage 0 and native output. No new syntax
or additional task-frame allocation was needed.

Previous upstream checkpoint: Z `d3f3367`. All 210 self-hosting-tier tests pass. After
restoring the unapplied draft, the normal native Z Notes smoke and both Zapp
TypeScript check projects pass as well.

The reduced TaskScope-handle continuation below now executes through both
Stage 0 and the native emitter. The awaited local remains owned through sequential
close/cancel joins; checked TaskScope receiver identities (including renamed
imports) distinguish these operations from arbitrary methods named `cancel`.

```zs
import { thread } from "std/thread";
import { TaskScope } from "std/async";

async function operation(): i32 on thread.main { return 0; }

async function startup(early: boolean, updates: TaskScope): i32 on thread.main {
  if (early) return await operation();
  const outcome = await operation();
  await updates.cancel();
  return outcome;
}

async function main(): i32 on thread.main {
  const updates = new TaskScope();
  return await startup(false, updates);
}
```

Same-executor joins register waiters and preserve child-before-parent cleanup;
separate-driver scopes retain the existing synchronous bridge. Bounded UBSan
tests cover simultaneous waiters, cold/active destruction, exact scope reference
counts, and the actual Z parent cancelled at 19 scheduler positions on both
success/error paths. Passed-in-handle checkpoint: Z `3732b1c`, with all 212
self-hosting-tier tests passing and the local compiler rebuilt to a fixed point.
The ordinary native Z Notes auto-closing smoke and all eight Stage 0/native
startup transport cases pass again under UBSan. This is a generic upstream
capability, not a change to the application source or a claim that this wrapper
now builds.

The local structural-ownership gate is now fixed upstream. Direct root-local
TaskScope constructors have implicit unwind states that close/join on return
and cancel/join on propagated failure or parent cancellation. Moving the visible
handle cannot skip its creating frame's join obligation. Scope children finish
before parent locals are destroyed, even when cancellation skips an explicit
source-level await. Nested/conditional constructors remain an explicit native
boundary. This added no new source syntax or Zapp API. Local ownership and
native callback re-entry checkpoint: Z `dec4079`.

The upstream probe covers two scopes, moved handles, free functions and supported
method frames, and 492 bounded native cancellation/destruction cases under UBSan.
All 215 self-hosting and 98 async tests pass, the local compiler reaches a fixed
point, and the eight production-shaped startup process cases pass again with
Stage 0 and native output under UBSan.

The full Z Notes smoke exposed and then verified an upstream native-entry fix:
WebKit callbacks re-entering while an outer Z poll is inside AppKit must use the
host driver, not merely queue work behind that blocked poll. The entry adapter
now restores the outer executor after the callback. The auto-closing native
smoke passes again, including frontend cancellation, WebView/service round trips,
worker messages and joins, and service teardown. No framework workaround was
added, and the saved integration patch remains unapplied.

The final reduced upstream gate is now fixed in Z `ef321a3`: a native-listener
cancellation join can follow an owned awaited outcome. An explicit worker cancel
completes normally; parent cancellation remains a separate structural outcome.
Root-owned worker handles join before parent cleanup even when an early return
or cancellation skips the explicit await. The compiler checks intrinsic Task or
imported thread.spawn identity, not merely a method named `cancel`.

Pending worker-to-main requests wake and resume the join frame through the
external queue. Main-isolated function owners and expression-bodied worker
placement now preserve their task identity. Cold/active waiter destruction drains
worker completion before freeing notification storage. The focused suite covers
300 parent-frame cancellation/destruction combinations plus 64 direct waiter
destruction cases under UBSan, functions without TaskScope, and main-bound methods.

The full upstream self-hosting run passed 218 tests; all 98 async tests passed.
The final focused suite passed 12 tests. The rebuilt compiler reached a fixed
point, all eight startup process cases passed again under UBSan, and the normal
native Z Notes auto-closing smoke passed with an isolated identity. The integration
patch remains unapplied: the next check is the actual full wrapper, not another
claim based only on reduced probes.

Do not rewrite the application around polling, a synchronous wrapper, or a
different public API merely to satisfy a lowering classifier.

The smaller same-module owned nested-match worker already passes through both
compilers with exact cleanup. Z also fixed normalized `try` ownership in arrays
and channels, object-destructured worker capture lookup, and Stage 0 nested async
match destinations during this work.

## Earlier continuation checkpoint

Z `ca5cd55` added frame-owned nested returned-match payloads and normalized
destructured locals, plus safe child-waiter teardown. Z `cd16a76` preserves
readonly collection ownership and closes the full application's cleanup crash.
All 226 upstream self-hosting tests pass, including both frontends' rejection
parity and a valid read/copy/await UBSan probe. These are ordinary language
composition fixes; no new framework API or Z syntax was added.

## Current upstream checkpoint

Z `0d03bd0` plans ordinary invocation-local cleanup inside synchronous captured block
callbacks, including the String returned by `json.encode`. The startup probe's
formatter is inline again, with no named-helper accommodation. Both compiler
paths pass reduced allocation-balance/destruction-order probes; the complete
native Application.run gate passes rollback and primary/secondary forwarding
with this inline callback. No public API changed.

Z `601c7f9` closes the adjacent destructuring rejection-parity gap. Native
checking now preserves Stage 0's conservative custom-cleanup boundary through
aliases, concrete generic fields, arrays, Map keys/values, Set elements, and
enum payloads. Supported ordinary owned fields and ARC aliases still work;
no public API or runtime allocation was added. All 232 upstream self-hosting
tests, 98 async tests, and focused UBSan ownership probes pass. The rebuilt
compiler reaches a fixed point, and the complete Application.run gate passes
again with that final compiler.

## Entry-defined service checkpoint (2026-09-09)

The upstream generated-link distinction is implemented. The startup probe now
defines its exported StartupProbe service beside main; the separate service
fixture has been removed. Generated dispatch remains ordinary Z and imports
that exported declaration. Only the source-hash/target-validated adapter
reference is a function link rather than a source initialization edge. Real
source cycles and visibility checks remain enforced.

The complete native Application.run gate passes again: endpoint failure before
AppKit, service-startup failure with joined listener cleanup, and primary/secondary
forwarding of empty/spaced/Unicode arguments and cwd exactly once. The secondary
creates neither an AppKit host nor started services. The integration required no
application API change or generated-source splicing.

The full build also caught a native lowering prerequisite: generated adapters
return their own ARC implementation types into generic registration methods.
The compiler now provides checked nominal ABI/cleanup evidence at each adapted
caller before emitting generated definitions. Reduced shared-driver regressions
cover owned inputs, distinct adapters, a shared adapter requested by multiple
modules, and UBSan cleanup. Stage 0 also isolates semantic sites for separate
generic method instances so one concrete trait receiver cannot overwrite another.

This closes the saved entry-module generation blocker. Separate service files
remain an organizational choice. Return to the framework/CLI sequence after
this checkpoint; deliberate any new public API before implementing it.

Upstream checkpoint: Z `591f92d`. All 232 self-hosting, 97 module/collection,
and 98 async tests pass, as do both drivers' expanded UBSan adapter probes.
The native compiler reaches a byte-identical fixed point (10,965,112 C bytes).
This repository's complete native startup gate and both TypeScript check
projects pass with that compiler.

Keep both gates available:

```sh
ZAPP_LAUNCH_UBSAN=1 bun cli/src/test-launch-startup-macos.ts
bun cli/src/test-application-startup-macos.ts
```

The first covers both Stage 0 and native transport output under UBSan. The second
builds the complete application with the selected compiler (native by default).
Do not describe the complete application gate as a dual-compiler run unless both
selections have actually been tested.

All new process tests use deadlines and process-tree cleanup. The transport
matrix uses UBSan; the complete application uses the signed native release
binary. Neither uses ASan. Interactive bundles and user-owned application
identities are not used by these tests.

## Z Notes developer-path checkpoint (2026-09-09)

Z Notes now enables the existing `application.singleInstance` option. Its
app-owned `secondInstanceLaunched` listener shows the main window and reports
only the argument count. URL-looking arguments do not implicitly invoke the
deep-link listener or gain file/service authority.

`bun cli/src/test-notes-launch-macos.ts` passes both packaged and Vite modes
with the fixed-point native compiler. Each mode uses a random identity and a
private smoke bundle, starts a second process after service startup, and checks:

- empty/spaced/Unicode/URL-looking arguments produce exactly one launch event;
- the secondary exits zero without starting another service, worker, or WebView;
- the primary completes its ordinary WebView and suspended worker-service checks;
- worker cancellation/join precedes service shutdown, and the endpoint is removed;
- the development command releases Vite port 5173.

The smaller full startup gate remains responsible for exact argument/cwd payload
comparison and failure rollback. This consumer gate proves the actual developer
commands and generated framework graph, not another reduced transport fixture.
Its build/run has a 240-second deadline and the secondary has a 15-second
deadline, with process-tree cleanup. No ASan is used.

This run exposed two upstream readonly parity gaps: numeric `length` evidence in
callback interpolation, and explicit copying of readonly Array storage. Native
checking also now rejects mutating frozen-collection methods before unknown-call
fallback. The worker generator had independently been extracting its owned
service-permission Array from a borrowed catalog; it now explicitly copies the
worker's startup snapshot. That is an intentional startup copy per worker,
not a per-call cost or a shared-ownership assumption.

Z `a1404d1` reaches a byte-identical fixed point (10,971,404 C bytes); all 233
self-hosting and 97 collection/module tests pass. Zapp's 502 CLI/runtime tests
and both TypeScript projects pass. The corresponding Z
ownership-pressure entry records the fixes and a separate readonly-alias indexed
interpolation follow-up. The generated-service/startup integration is no longer
blocking framework or CLI work; new public surfaces still require deliberation.
