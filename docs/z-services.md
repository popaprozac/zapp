# Z-owned services

Status: first typed vertical slice implemented, August 2026.

Zapp services are ordinary Z values whose public methods become typed frontend
bindings. A service is a `struct` by default. It may contain `Mutex<T>`, native
owners, or ARC references when its behavior needs those capabilities; service
registration does not force every service into a class hierarchy.

## Application surface

The public lifecycle is designed around a consuming application builder:

```z
let app = Application({ name: "Notes" });
app.services.register("notes", createNotesService());
return try app.run();
```

`app.run()` consumes the mutable configuration, freezes its service routing
table, publishes the runtime application identity, and blocks until shutdown.
There is no user-facing `finish()` call. Internally, `freeze()` names the exact
mutable-builder to readonly-router transition and matches Z collection
vocabulary.

## Lifecycle is explicit and exceptional

Most services do not need framework lifecycle hooks. They acquire owned
resources when they are constructed and release them deterministically through
the resource's `deinit`. Services that genuinely need application-wide startup
or shutdown work will opt into one contract:

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

Lifecycle work is deliberately separate from the frozen service router. The
router remains `on thread.any` for WebView and embedded-engine calls; storing
main-only lifecycle callables inside it would make the entire fast path
main-isolated. `Application.run(move this)` creates the immutable
`ApplicationContext`, starts lifecycle services before entering the platform
run loop, and stops them after the loop returns.

The fixed-point compiler executes constrained trait calls through static
specialization: generated C calls the concrete service method directly,
without a vtable or trait-object allocation. Z does not yet provide
trait-typed storage or dynamic dispatch. `ServiceLifecycleBuilder.register`
accepts the concrete service through a `T: ServiceLifecycle` constraint and
constructs one main-qualified adapter internally. The fixed-point compiler
specializes that framework-owned generic method over an application-private
service type, preserves cleanup through the captured hook, and emits direct
concrete method calls. Application authors write only:

```z
let lifecycles = createServiceLifecycles();
lifecycles.register("notes", createNotesService());
```

The permanent smoke under `native/z/smokes/service-lifecycle/` proves normal
order, failed-start rollback, complete best-effort shutdown, and the generic
cross-module registration path.

The Phase 1 native application uses that surface directly in
`native/z/app.zs`. `Application({ name })` creates a fresh service builder through a
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

The Z core owns one frozen `readonly Map<String, ServiceHandler>`. Each handler
is an `on thread.any` callable whose captured graph must be deeply shareable.
The `NotesService` probe is a readonly value struct containing
`Mutex<NotesState>`, so mutable state is synchronized inside the service rather
than making the routing table mutable after publication.

The strict C host additionally calls `zapp_invoke_service_owned` directly. It
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

## Metadata status

`native/z/services.zmeta.json` is the versioned Phase 1 input to binding
generation. It deliberately models semantic service types and methods rather
than scanning Z source with regular expressions. Today it accompanies the
concrete generated-style `NotesService` adapter because the compiler does not
yet export service metadata.

The intended next step is compiler-produced metadata derived from checked Z
symbols. Application authors should not maintain a second TypeScript schema,
and a stale or incompatible metadata version must fail closed.

## First performance checkpoint

Measured on the Apple M4 Max development machine with a release Z library and
size-optimized strict C host:

| Metric | Result |
|---|---:|
| Direct `notes.count` after warmup | 273–287 ns/call |
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
- Async service methods, typed invocation errors, cancellation, and permissions
  remain follow-up composition work. Lifecycle ordering and typed lifecycle
  failures are implemented; exporting and consuming compiler-generated service
  metadata remains future work.
- The sample app is still a framework-owned staged entry. Selecting an
  application project's own `.zs` entry and deriving service metadata from its
  checked exports are the next productization steps.

None of these gaps changes the intended application-facing API.
