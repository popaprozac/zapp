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
- The Stage 0 UBSan matrix passes real primary/secondary processes, idle
  cancellation, a partial native request during shutdown, and a hostile socket
  path during startup. It checks one delivery, arguments/cwd snapshots, ordered
  joins, lease reacquisition, and socket cleanup.
- The proposed full Z Notes graph checks with Stage 0. This is **not** an
  executable application integration result.
- Generated metadata now exposes the existing `application.singleInstance`
  setting as a private build hook, default false. No new configuration key was
  introduced, and the hook is not yet called by Application.run.

## Remaining upstream blocker

With native headers present, native lowering renames private/internal async
functions to avoid C-symbol collisions. The imported call to
`listenMacOSApplicationLaunches` retains its unmangled target while the callee
has a module-qualified emitted name. The worker bridge cannot find its yielding
frame and rejects emission. The improved diagnostic names that unresolved target.

This is not a reason to expose the function publicly, remove native symbol
hygiene, bypass cancellation, or add an Objective-C listener shim. Fix call
identity upstream using the checked target module/symbol identity. Verify
renamed imports, two same-named internal targets, same-module calls, and native
header builds; do not resolve calls using an ambiguous suffix/name search.

The smaller same-module owned nested-match worker already passes through both
compilers with exact cleanup. Z also fixed normalized `try` ownership in arrays
and channels, object-destructured worker capture lookup, and Stage 0 nested async
match destinations during this work.

## Resume sequence

1. Fix and regress the cross-module internal async-call identity in Z.
2. Rebuild the fixed-point compiler, then require the complete process matrix:

   ```sh
   ZAPP_LAUNCH_UBSAN=1 ZAPP_LAUNCH_REQUIRE_NATIVE=1 bun cli/src/test-launch-startup-macos.ts
   ```

   Without `ZAPP_LAUNCH_REQUIRE_NATIVE=1`, the harness verifies Stage 0 and
   explicitly reports the exact known native boundary. It does not call that a
   native runtime pass. Any different diagnostic still fails.
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
