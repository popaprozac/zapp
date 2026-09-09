# Application startup integration checkpoint

Automatic forwarding is now wired into macOS `Application.run()` when the
existing `application.singleInstance` setting is true. The saved draft has been
applied and its obsolete patch removed. The disabled path creates no listener,
readiness channel, or delivery scope.

## Verified

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

## Next checkpoint

Revisit entry-module service generation: a service declared in main currently
creates a generated-dispatch import cycle. Separate service modules work and
are used by this regression and Z Notes. Do not weaken Z module-cycle checks
to hide a generator dependency problem. This is the next framework/compiler
integration issue, not a reason to introduce a different service API.

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
