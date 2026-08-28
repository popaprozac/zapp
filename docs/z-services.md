# Z-owned services

Status: synchronous and suspending typed vertical slices implemented through
headless and AppKit/WebView hosts, August 2026.

Zapp services are ordinary Z values whose public methods become typed frontend
bindings. A route-only service may be a `struct`. A service that shares one
mutable identity between request handling and application lifecycle hooks is
naturally an ARC `class`, usually with its mutable state behind `Mutex<T>`.
Registration does not force every service into a class hierarchy.

The reusable service machinery lives under `native/z/framework/`. The concrete
Notes core, transport adapters, and application entries live under
`spikes/z-notes/zapp/`; no framework module imports an application type.

## Application surface

The public lifecycle is designed around a consuming application builder:

```z
async function main(): i32 throws WindowError on thread.main {
  let app = Application();
  app.services.register("notes", createNotesService());
  const mainWindow = try app.windows.create(WindowOptions({
    title: "Notes",
    url: "/notes",
    width: 900,
    height: 640,
  }));
  return match (attempt await app.run()) {
    success(status) => status;
    failure(_) => 70;
  };
}
```

The CLI compiles the resolved `zapp.config.ts` application name, identifier,
and version into the readonly `app.metadata` value. `app.run()` consumes the
mutable builder, freezes its service routing table and metadata, publishes the
runtime application identity, and asynchronously remains attached to the
blocking platform run loop until shutdown.
There is no user-facing `finish()` call. Internally, `freeze()` names the exact
mutable-builder to readonly-router transition and matches Z collection
vocabulary.

`app.windows` is a readonly class reference: application code cannot replace
the manager, while its main-executor methods may safely update the manager's
owned state. This is Z's shallow `readonly` contract, not a recursive freeze.
`WindowOptions()` supplies defaults, and each successful `create` returns a
stable ARC `Window` handle with `show`, `hide`, `setTitle`, and idempotent
`close` operations. The current macOS vertical slice realizes one window
registered before `run`; native dynamic and multi-window realization are
explicit follow-up work.

The window URL is application-relative and stable across environments. Zapp
resolves `/notes` against the Vite/Bun development origin or the packaged
embedded-asset origin; service code and generated bindings see the same page
and bridge in either mode.

`Application.run` throws the exhaustive `ApplicationError` enum. Service
lifecycle failures remain typed as its `lifecycle` variant, while window and
platform setup failures use `window` and `platform`. This keeps one application
boundary without flattening the underlying failure contracts into integers.

## Lifecycle is explicit and exceptional

Most services do not need framework lifecycle hooks. They acquire owned
resources when they are constructed and release them deterministically through
the resource's `deinit`. Those services use `register`. A service that genuinely
needs application-wide startup or shutdown work also implements one contract:

```z
trait ServiceLifecycle {
  function start(
    in context: ApplicationContext
  ): void throws ServiceLifecycleError on thread.main;

  function stop(
    in context: ApplicationContext
  ): void throws ServiceLifecycleError on thread.main;
}
```

The runtime ordering is already executable. Starts run in registration order.
If one start fails, every service that already started is stopped in reverse
order before the original start error is propagated. Normal stops run in
reverse order, attempt every service even after an error, and then propagate
the first reverse-order stop error.

The application surface has one registration operation:

```z
app.services.register("health", createHealthService());
app.services.register("database", createDatabaseService());
app.services.register("search", createSearchService());
app.services.register("notes", createNotesService());
```

The checked method metadata selects a synchronous adapter when every public
method is synchronous and executor-neutral, or an async adapter when any method
can suspend or requires `thread.main`. Implementing `ServiceLifecycle` adds the
lifecycle forwarder. Application authors do not choose the transport adapter or
register one object twice.

`ApplicationServicesBuilder.register` is deliberately a build marker during
the first metadata pass. The Zapp build verifies and replaces it only in an
isolated staged copy, then the final native compilation calls an internal typed
runtime registration method. The original source remains valid for editor and
metadata checks, but a Zapp application is built with `zapp`, not by invoking
its entry directly with bare `z run`.

Lifecycle storage remains deliberately separate from the frozen service router
inside the framework. The router stays `on thread.any` for WebView and
embedded-engine calls; storing main-only lifecycle callables inside it would
make the entire fast path main-isolated. `Application.run(move this)` is async,
freezes both stores, creates the immutable `ApplicationContext`, starts
lifecycle services before entering the platform run loop, then cancels and
joins every accepted callback-created operation before stopping services after
the loop returns.

The fixed-point compiler executes constrained trait calls through static
specialization: generated C calls the concrete service method directly,
without a vtable or trait-object allocation. Z does not yet provide
trait-typed storage or dynamic dispatch.
The generated adapter accepts the concrete service, preserves cleanup through
its stored identity and lifecycle forwarding, and emits direct concrete method
calls. Application authors write only:

```z
app.services.register("notes", createNotesService());
```

The permanent smoke under `native/z/smokes/service-lifecycle/` proves normal
order, failed-start rollback, complete best-effort shutdown, and the generic
cross-module registration path. It also proves that a lifecycle-aware service's
handler and hooks retain the same ARC identity through start, invocation, and
stop.

The Phase 1 Notes application uses that surface directly in
`spikes/z-notes/zapp/main.zs`. `Application()` receives immutable generated
metadata and creates a fresh service builder through value-field defaults; the
main-thread `run(move this)` method consumes the whole configuration. Z owns
the executable `main`; the Objective-C file is a linked platform adapter with
no framework policy or entry point of its own.

The underlying transition remains available to framework internals and focused
tests:

```z
let services = createServices();
services.register("notes", createNotesService());
const published = services.freeze();
```

## One binding, two transports

The generated TypeScript API is transport-independent:

```ts
import { notes } from "./.zapp/generated/services";

const note = await notes.create({ title: "Draft" });
const count = await notes.count();
```

In a WebView, `Services.invoke` sends the call through the document-start
bridge. In an embedded zjs worker, the same generated module selects the
existing direct-host fast path. Application code and generated method names do
not change with the JavaScript execution environment.

## Per-request cancellation

Generated WebView bindings accept the standard `AbortSignal` shape and retain
their explicit `cancel()` escape hatch:

```ts
const controller = new AbortController();
const pending = notes.create(
  { title: "Draft" },
  { signal: controller.signal },
);

controller.abort();
// Equivalently: pending.cancel();
await pending; // rejects with AbortError
```

An already-aborted signal prevents the request from crossing the bridge. Once
submitted, cancellation removes the browser-side pending entry immediately and
sends the request identity to Z. A main-isolated pending-request registry maps
that identity to the `TaskControl` returned by the application-owned
`TaskScope`; cancellation removes the registry entry and requests cooperative
cancellation. Mutable request state never crosses the scheduling boundary—task
closures carry only scalar identifiers and generations. Completed requests
remove their abort listeners and timers, so aborting a reused controller cannot
affect work that already finished. Reused wire identifiers are guarded by a
native generation, preventing an older completion from deleting a newer
request with the same identifier.

Service routing is deliberately not declared `on thread.main`. After the
service task resolves, one explicit placed call finishes the pending generation
and publishes the response on main. The current WebKit callback already runs on
main and therefore takes the zero-hop path; retaining the explicit boundary
keeps native delivery compiler-checked and leaves service execution ready for a
future worker or pool executor.

This end-to-end cancellation path currently applies to WebView invocations.
The embedded-worker direct-host path retains its allocation-lean synchronous or
host-owned async behavior; cancellable worker-host calls require a corresponding
native host adapter rather than pretending that local Promise rejection stopped
native work.

The application runtime owns one frozen `ServiceHandler` map and one frozen
`AsyncServiceHandler` map. `services.zs` remains entirely synchronous;
`application-services.zs` composes that router with the async registry and
lifecycle hooks only for applications that need them. Keeping the graphs
separate means synchronized or pure services retain the direct synchronous
fast path, and a strict embedded host does not link task machinery merely
because the framework also supports suspending services. Registering one
suspending service does not allocate a task for every service call. Each handler is an
`on thread.any` callable whose captured graph must be deeply shareable.
The `NotesService` probe is a readonly ARC class containing a `NotesCore`,
whose state is protected by `Mutex<NotesState>`, so its handler and lifecycle adapter share identity while
mutable state remains synchronized instead of making the routing table mutable
after publication.

The Notes domain behavior lives once in `NotesCore`. `NotesService` adds the
suspending desktop and lifecycle contracts; `SyncNotesService` is a thin direct
host adapter over that same core. The strict C host calls
`zapp_invoke_service_owned` directly. It
proves that an embedded engine can bypass the WebView envelope and reach the
same handler and retained service state. Wiring that entry into zjs is a host
adapter task, not a second service system.

## Exact values at the JavaScript boundary

Z `u64` and `i64` values do not become JavaScript `number`; that would silently
lose precision. Their JSON wire representation is a decimal string and the
generated TypeScript surface exposes `bigint`:

```ts
interface Note {
  id: bigint;
  title: string;
}
```

The generated decoder validates and converts the wire value. Other numeric
types map to `number` only when that mapping preserves the declared contract.

## Compiler-produced metadata

The fixed-point Z compiler now owns the source of truth. `z metadata` emits a
versioned, framework-neutral artifact containing checked public symbols,
resolved public call sites, literal arguments, and non-literal argument types.
Zapp recognizes synchronous and async application registrations, including:

```z
app.services.register("notes", createNotesService());
```

It resolves `NotesService`, its public methods, and the exported request and
response structs from compiler evidence, then derives the transport manifest
and TypeScript bindings. No regular-expression source scanner and no
hand-maintained `services.zmeta.json` remain. The generated program and service
artifacts live under the application's gitignored `.zapp/z-native-core/`
directory for inspection. Unknown compiler or metadata schema versions fail
before native compilation.

## Current service handler boundary

The native build now installs a generated adapter into the isolated staged
application source. The checked application source is never rewritten. Zapp
verifies the compiler-provided registration offset, imports the generated
adapter, and selects the staged sync/async runtime path. A stale
or mismatched source location fails the build instead of silently routing a
different value. The Z Notes WebView smoke therefore reaches `create` and
`count` through generated Z codecs and dispatch. The service contains no
transport method.

Synchronous registrations use a generated `Service` adapter and the existing
allocation-lean map. Suspended or main-isolated methods use a generated
`AsyncService` adapter. Zapp does not silently turn a sync-only service into a
task.

The internal runtime builders remain generic over the framework's `Service`
and `AsyncService` traits, so the framework does not know about Notes or any
other concrete application type. Generated adapters provide those internal
contracts from an ordinary service:

```z
export readonly class NotesService implements ServiceLifecycle {
  function create(input: CreateNoteInput): Note { /* ... */ }
  async function count(): u64 on thread.main { /* ... */ }

  function start(in context: ApplicationContext)
    : void throws ServiceLifecycleError on thread.main { /* ... */ }

  function stop(in context: ApplicationContext)
    : void throws ServiceLifecycleError on thread.main { /* ... */ }
}
```

Only `create` and `count` become generated frontend methods. No author-facing
`invoke`, transport type, route table, or `AsyncService` conformance remains.
Registration owns the service name, so the service does not duplicate its
route list or capture its registered name. There is no hand-authored route
schema.

Application authors do not write `createNotesHandler` or another callable
factory. Zapp generates the codecs, method dispatch, `AsyncService` adapter,
and lifecycle forwarding over the concrete service. The compiler validates
that concrete captured graph before publishing it. A mutable or otherwise
non-shareable service fails at registration with the reason its capture cannot
cross arbitrary threads; `Mutex<T>` and deeply readonly ARC services satisfy
the established sharing rules.

The generated adapter decodes `ServiceInvocation`, calls the typed public
methods, and encodes `ServiceOutcome`. The application source remains ordinary
Z and does not depend on those transport contracts.

## Async services

The current `ServiceHandler` is synchronous and callable `on thread.any`. It
executes on the thread that enters the registry; the qualifier proves placement
safety but does not create a task or switch executors. This is the efficient
default for pure work, synchronized shared state, and thread-safe native APIs.

A service that must suspend—for example, a request that waits for I/O or awaits
main-thread AppKit work—simply declares an async or executor-qualified public
method. The framework generates this stored handler contract:

```z
type AsyncServiceHandler =
  async (in invocation: ServiceInvocation) => ServiceOutcome on thread.any;
```

Application code remains concrete and ordinary:

```z
readonly class SearchService {
  async function find(input: SearchInput): SearchResult {
    return await searchIndex(move input);
  }
}

app.services.register("search", new SearchService({}));
```

`AsyncServices.invoke` first checks the synchronous map, allowing one async
bridge path to serve both service kinds without penalizing direct synchronous
callers. If no synchronous service owns the name, it retains the selected async
callable out of the frozen map before suspension and awaits it as a structured
child. The map loan therefore never crosses `await`.

The permanent smoke under `native/z/smokes/async-service/` executes a complete
headless request path: JSON bridge envelope → frozen async registry → genuinely
suspended Z service (`await scheduler.yield()`) → typed bridge response. It
then schedules a second operation parked in scheduler-aware `delay`, records
its `TaskControl`, cancels it by request ID, and proves that the continuation
after the delay never runs. A later request still completes successfully, so
the proof covers cancellation isolation rather than merely closing the whole
scope. Run it from the Z repository with:

```bash
bun run z run /Users/zach/code/zapp/native/z/smokes/async-service
```

Stage 0 and the fixed-point compiler both execute the unchanged smoke. Cancelling
the timer-backed child removes its pending timer immediately, so the test is
deterministic and does not wait for the one-second delay to expire. The desktop
host uses the intended product surface, `app.services.register(...)`. Its
`WKScriptMessageHandler` submits the owned request to an application
`TaskScope`; the service may suspend, completion is published on the main
executor, and shutdown rejects new work before cancelling and joining accepted
operations. Generated TypeScript sees an ordinary `Promise` for both service
kinds.

## First performance checkpoint

Measured on the Apple M4 Max development machine with a release Z library and
size-optimized strict C host:

| Metric | Result |
|---|---:|
| Direct `notes.count` after warmup | 257–279 ns/call |
| Work inside that measurement | Frozen-map lookup, callable thunk, synchronized scalar read, JSON response encoding, C callback |
| Pre-service strict host | 71,216 bytes |
| Typed-service strict host | 89,168 bytes |
| Executable growth | 17,952 bytes |
| Pre-service Z archive | 43,552 bytes |
| Typed-service Z archive | 56,592 bytes |
| Archive growth | 13,040 bytes |

These numbers are a regression checkpoint, not a framework comparison. WebView
calls intentionally pay JSON transport cost. Direct embedded-engine calls
should eventually convert typed values at the engine boundary without encoding
an intermediate JSON document.

## Gaps exposed by the slice

- Z has no first-class build-macro or generated-module hook yet, so Zapp
  installs adapter imports and calls into an isolated staged copy. Compiler
  offsets are verified and mismatches fail closed; a future compiler-owned
  hook could remove this textual staging seam without changing user syntax.
- Sync-only struct services currently need to be copyable when captured by the
  generated ARC adapter. Async services require class identity. Move-only
  struct adapters remain fail-closed until compiler metadata exposes a checked
  copy/move capability instead of making the generator guess.
- Native cross-module specialization of `json.decode<UserType>` and
  `json.encode(in value)` is implemented for the current scalar,
  `Array<String>`, and exported-struct codec tier. The generated adapter still
  keeps explicit codecs where its wire contract needs exact integer handling.
- `Mutex.withLock` returns are limited to cleanup-free values in the native
  compiler. The service keeps the critical section scalar and constructs owned
  results after unlocking.
- Headless and WebView async service routes, per-request cancellation,
  lifecycle ordering, lifecycle failures, and compiler-generated bindings are
  implemented. Native bridge failures now carry structured codes and become
  `ZappInvocationError` subclasses in TypeScript. Throwing service methods and
  service-specific permissions remain follow-up composition work; when Z error
  metadata enters the service manifest, generated bindings should emit named
  error classes rather than flattening those failures into strings.
- Generated async dispatch currently supports one suspending method per service
  and no owned request value across that suspension. These are native async
  frame composition limits, not intended application API restrictions.
- The in-tree Notes project now supplies its own `.zs` entries. A stable local
  package/module contract is the next productization step; it must work in both
  semantic frontends and the editor rather than relying on staging rewrites.

None of these gaps changes the intended application-facing API.
