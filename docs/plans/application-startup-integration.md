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

Upstream checkpoint: Z `d3f3367`. All 210 self-hosting-tier tests pass. After
restoring the unapplied draft, the normal native Z Notes smoke and both Zapp
TypeScript check projects pass as well.

The full Application.run wrapper now stops on the following additional shape:
joining a TaskScope after that awaited local. This reduced ordinary Z program
runs with Stage 0 but receives Z0700 from the fixed-point native compiler:

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

The native diagnostic now identifies a broader continuation-frame requirement
instead of reporting a timer-only lowering error. In the full graph it points
at `const outcome = attempt await runMacOSReadyApplication(...)`; the subsequent
native listener cancellation and TaskScope joins are the additional suspensions.
Fix these upstream with checked receiver identities and cancellation/cleanup
tests. Do not simply ignore every method named `cancel` in frame admission.
Do not rewrite the application around polling, a synchronous wrapper, or a
different public API merely to satisfy a lowering classifier.

The smaller same-module owned nested-match worker already passes through both
compilers with exact cleanup. Z also fixed normalized `try` ownership in arrays
and channels, object-destructured worker capture lookup, and Stage 0 nested async
match destinations during this work.

## Resume sequence

1. Compose the native post-await continuation with TaskScope cancellation/join,
   then native-thread cancellation/join. Preserve the owned outcome and parent
   storage until every admitted child has joined. Early return + awaited local
   alone is now covered; avoid expanding unrelated nested-local/yield shapes.
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
