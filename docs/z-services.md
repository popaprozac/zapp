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
async function main(): i32 on thread.main {
  let app = Application({ name: "Notes" });
  app.services.registerAsyncWithLifecycle(
    "notes",
    createNotesService()
  );
  return try await app.run();
}
```

`app.run()` consumes the mutable configuration, freezes its service routing
table, publishes the runtime application identity, and asynchronously remains
attached to the blocking platform run loop until shutdown.
There is no user-facing `finish()` call. Internally, `freeze()` names the exact
mutable-builder to readonly-router transition and matches Z collection
vocabulary.

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

The application surface has four explicit choices:

```z
app.services.register("health", createHealthService());
app.services.registerWithLifecycle("database", createDatabaseService());
app.services.registerAsync("search", createSearchService());
app.services.registerAsyncWithLifecycle("notes", createNotesService());
```

`registerWithLifecycle` requires `T: Service & ServiceLifecycle`, while its
async counterpart requires `T: AsyncService & ServiceLifecycle`. Each derives
the route handler and lifecycle adapter from the same service value, so
application authors do not register one object twice. The separate methods are intentional in
this tier: Z does not yet inspect a generic value for an optional trait and
conditionally synthesize behavior. A future compiler-owned implementation may
make plain `register` detect `ServiceLifecycle` automatically without changing
the service contracts.

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
`ApplicationServicesBuilder.registerAsyncWithLifecycle` accepts the concrete
service through a `T: AsyncService & ServiceLifecycle` constraint and
constructs the async handler plus main-qualified lifecycle adapter internally.
The compiler specializes that
framework-owned generic method over an application-private service type,
preserves cleanup through the captured hook, and emits direct concrete method
calls. Application authors write only:

```z
app.services.registerAsyncWithLifecycle("notes", createNotesService());
```

The permanent smoke under `native/z/smokes/service-lifecycle/` proves normal
order, failed-start rollback, complete best-effort shutdown, and the generic
cross-module registration path. It also proves that a lifecycle-aware service's
handler and hooks retain the same ARC identity through start, invocation, and
stop.

The Phase 1 Notes application uses that surface directly in
`spikes/z-notes/zapp/main.zs`. `Application({ name })` creates a fresh service builder through a
value-field default, and the main-thread `run(move this)` method consumes the
whole configuration. Z owns the executable `main`; the Objective-C file is a
linked platform adapter with no framework policy or entry point of its own.

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
sends the request identity to Z. The application-owned `TaskScope` maps that
identity to its `TaskControl` and requests cooperative cancellation. Completed
requests remove their abort listeners and timers, so aborting a reused
controller cannot affect work that already finished. Reused wire identifiers
are guarded by a native generation, preventing an older completion from
deleting a newer request with the same identifier.

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
app.services.registerAsyncWithLifecycle("notes", createNotesService());
```

It resolves `NotesService`, its public methods, and the exported request and
response structs from compiler evidence, then derives the transport manifest
and TypeScript bindings. No regular-expression source scanner and no
hand-maintained `services.zmeta.json` remain. The generated program and service
artifacts live under the application's gitignored `.zapp/z-native-core/`
directory for inspection. Unknown compiler or metadata schema versions fail
before native compilation.

## Current service handler boundary

The registration builders are generic over the framework's `Service` trait, so
the framework does not know about Notes or any other concrete application
type. A service supplies one non-consuming conversion into the framework's
thread-safe callable:

```z
export readonly class NotesService implements AsyncService, ServiceLifecycle {
  function create(input: CreateNoteInput): Note { /* ... */ }
  function count(): u64 { /* ... */ }

  async function invoke(
    in invocation: ServiceInvocation
  ): ServiceOutcome {
    await scheduler.yield();
    /* decode the checked route and call create/count */
  }

  function start(in context: ApplicationContext)
    : void throws ServiceLifecycleError on thread.main { /* ... */ }

  function stop(in context: ApplicationContext)
    : void throws ServiceLifecycleError on thread.main { /* ... */ }
}
```

Only `create` and `count` become generated frontend methods. `invoke` is a
framework capability and is filtered from the compiler-produced public service
surface. Registration owns the service name and strips that prefix before
invocation, so the service does not duplicate its route list or capture its
registered name. There is no `ServiceBinding`, application adapter class, or
second hand-authored route schema.

Application authors do not write `createNotesHandler` or another callable
factory. The framework's generic `registerAsync<T: AsyncService>` specialization
creates the `on thread.any` async closure over the concrete service, and the
compiler validates that concrete captured graph before publishing it. A mutable or otherwise
non-shareable service fails at registration with the reason its capture cannot
cross arbitrary threads; `Mutex<T>` and deeply readonly ARC services satisfy
the established sharing rules.

The remaining handwritten `invoke` method is the current checked wire adapter:
it decodes `ServiceInvocation`, calls the service's typed public methods, and
encodes `ServiceOutcome`. Compiler-produced service metadata already knows
those methods and types, so synthesizing this final router is a future Zapp
code-generation step rather than a permanent per-service factory convention.

## Async services

The current `ServiceHandler` is synchronous and callable `on thread.any`. It
executes on the thread that enters the registry; the qualifier proves placement
safety but does not create a task or switch executors. This is the efficient
default for pure work, synchronized shared state, and thread-safe native APIs.

A service that must suspend—for example, a request that waits for I/O or awaits
main-thread AppKit work—implements `AsyncService`. The framework synthesizes
this stored handler contract:

```z
type AsyncServiceHandler =
  async (in invocation: ServiceInvocation) => ServiceOutcome on thread.any;
```

Application code remains concrete and ordinary:

```z
readonly class SearchService implements AsyncService {
  async function invoke(
    in invocation: ServiceInvocation
  ): ServiceOutcome {
    const result = await searchIndex(in invocation.arguments);
    return ServiceOutcome.success(move result);
  }
}

let services = createAsyncServices();
services.registerAsync("search", new SearchService({}));
const published = services.freeze();
```

`AsyncServices.invoke` first checks the synchronous map, allowing one async
bridge path to serve both service kinds without penalizing direct synchronous
callers. If no synchronous service owns the name, it retains the selected async
callable out of the frozen map before suspension and awaits it as a structured
child. The map loan therefore never crosses `await`.

The permanent smoke under `native/z/smokes/async-service/` executes the first
complete headless request path: JSON bridge envelope → frozen async registry →
genuinely suspended Z service (`await scheduler.yield()`) → typed bridge
response. Its `validateRoutes()` function performs two sequential bridge awaits
through one heap-owned task frame, proving that the service graph no longer
depends on `async main` blocking each route independently. Run it from the Z
repository with:

```bash
bun run z run /Users/zach/code/zapp/native/z/smokes/async-service
```

Both semantic frontends agree on this module graph, and the fixed-point emitter
strict-C compiles and executes it. The current reusable frame supports two
top-level awaited local bindings with owned storage and active-child
cancellation; arbitrary suspension graphs remain language work. The desktop
host uses the intended product surface, `app.services.registerAsync(...)`. Its
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

- Trait constraints execute through zero-vtable static dispatch, including
  framework-owned generic functions and methods instantiated with an
  application-private downstream type. Lifecycle adapters no longer require
  generated application-side source.
- Native cross-module specialization of `json.decode<UserType>` is incomplete;
  the generated adapter currently projects `JsonValue` explicitly.
- `Mutex.withLock` returns are limited to cleanup-free values in the native
  compiler. The service keeps the critical section scalar and constructs owned
  results after unlocking.
- Headless and WebView async service routes are implemented. Typed invocation
  errors beyond `ServiceOutcome`, per-request cancellation, and permissions
  remain follow-up composition work. Lifecycle ordering, typed
  lifecycle failures, and compiler-generated binding metadata are implemented.
- The in-tree Notes project now supplies its own `.zs` entries. A stable local
  package/module contract is the next productization step; it must work in both
  semantic frontends and the editor rather than relying on staging rewrites.

None of these gaps changes the intended application-facing API.
