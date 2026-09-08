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
  build remains blocked on the separate frame-composition gap below. No app was
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

The full Application.run wrapper exposes a separate native frame-composition
gap: an early awaited return followed by a later awaited local. The minimized
ordinary Z reproducer is:

```zs
import { thread } from "std/thread";

async function operation(): i32 on thread.main { return 42; }

async function startup(enabled: boolean): i32 on thread.main {
  if (!enabled) return await operation();
  const result = await operation();
  return result;
}

async function main(): i32 on thread.main {
  const observed = await startup(true);
  return observed - 42;
}
```

Stage 0 runs this successfully. The native compiler reports the misleading
timer-only lowering error (`requires every suspension ... await delay`). Its
separate branched-tail and linear-awaited-local classifiers do not compose yet.
Fix this upstream, including precise unsupported-shape diagnostics, then verify
the full wrapper's owned outcome and listener/TaskScope cancellation joins.
Do not rewrite the application around polling, a synchronous wrapper, or a
different public API merely to satisfy a lowering classifier.

The smaller same-module owned nested-match worker already passes through both
compilers with exact cleanup. Z also fixed normalized `try` ownership in arrays
and channels, object-destructured worker capture lookup, and Stage 0 nested async
match destinations during this work.

## Resume sequence

1. Compose early awaited returns with later awaited locals in native frames;
   test both branches, owned locals/results, typed failures, and cancellation.
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
