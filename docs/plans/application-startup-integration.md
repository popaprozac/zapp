# Application startup integration checkpoint

The application launch path is unchanged. Automatic forwarding is **not enabled**.
The adjacent `application-startup-integration.patch` preserves the implementation
draft without importing it into the shipping macOS application graph.

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
- The proposed full Z Notes graph checks with Stage 0, but the native application
  build remains blocked on the scope/thread-join composition gap below. No app was
  launched by the failed integration build; the patch was returned to this saved
  state. This is **not** an executable application integration result.
- After restoring the unapplied state, the full native Z Notes auto-closing smoke
  passes with an isolated application identity: WebView/service round trips,
  application-worker messages, cancellation/join, and service teardown remain
  working. Both TypeScript check projects also pass.
- Generated metadata now exposes the existing `application.singleInstance`
  setting as a private build hook, default false. No new configuration key was
  introduced, and the hook is not yet called by Application.run.

## Remaining upstream blocker

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
success/error paths. Latest upstream checkpoint: Z `3732b1c`, with all 212
self-hosting-tier tests passing and the local compiler rebuilt to a fixed point.
The ordinary native Z Notes auto-closing smoke and all eight Stage 0/native
startup transport cases pass again under UBSan. This is a generic upstream
capability, not a change to the application source or a claim that this wrapper
now builds.

Two gates remain in the full wrapper:

- Native-listener cancellation/join after the owned outcome still needs a
  continuation state. Do not confuse an explicit worker cancel (which completes
  normally) with cancellation of the parent task itself.
- `launchUpdates` is created inside the wrapper, not merely passed in. An
  additional upstream probe showed that cancelling a native parent before such
  a scope's explicit join can leave scheduled children/timers alive. The native
  linear frame now rejects locally created TaskScope owners with `Z0700` until
  implicit scope-unwind states join those children on every exit. Passing handle
  tests do not establish local structural ownership.

Fix both upstream with cancellation/cleanup tests. Do not simply ignore every
method named `cancel` in frame admission.
Do not rewrite the application around polling, a synchronous wrapper, or a
different public API merely to satisfy a lowering classifier.

The smaller same-module owned nested-match worker already passes through both
compilers with exact cleanup. Z also fixed normalized `try` ownership in arrays
and channels, object-destructured worker capture lookup, and Stage 0 nested async
match destinations during this work.

## Resume sequence

1. Implement implicit unwinding for continuation-owned TaskScopes, then
   native-thread cancellation/join. Passed-in TaskScope joins are now covered.
   Preserve the owned outcome and parent storage until every admitted child has
   joined, even when cancellation skips a source-level explicit await. Avoid
   expanding unrelated nested-local/yield shapes.
2. Rebuild the fixed-point compiler, then rerun the complete process matrix:

   ```sh
   ZAPP_LAUNCH_UBSAN=1 bun cli/src/test-launch-startup-macos.ts
   ```

   Both compiler builds and all eight runtime cases are required by default.
   The former expected-native-failure escape has been removed.
3. Review and apply the saved integration patch. Its single-instance-disabled
   path allocates no listener, queue, or delivery scope. The enabled path keeps
   an owned outcome until listener and callback-scope teardown have joined.
4. Run the full native Z Notes smoke with an isolated identity. Add a complete
   Application.run primary/secondary gate test and startup failure rollback;
   check that a secondary never creates windows or starts services.
5. Only then enable/claim automatic forwarding and update activation docs.

All new process tests use deadlines and process-tree cleanup. They use UBSan,
not ASan. The existing interactive bundle and user-owned application identities
are not used by the transport matrix.
