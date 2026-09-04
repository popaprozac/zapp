# Z Native Core Rewrite Charter

Status: accepted direction, August 2026.

Implementation status: Phase 0 is complete. The framework-owned `native/z/`
static library, compiler-identity gate, embedding lifecycle host, and promoted
message-boundary smoke are implemented and build through the ordinary
kitchen-sink CLI path. Phase 1's generated-runtime-owned Z `Application`, typed
JSON ingress, first typed handler, typed response callback, and first visible
AppKit/WebKit round trip are implemented. The Z root now owns the WebKit
protocol handler, dynamic message-body validation, owned string conversion,
deterministic registration guard, window/WebView construction, and the first
frozen typed service router. The first Z-owned frontend loader now resolves one
logical `Window.url` through a development HTTP origin or a packaged
`zapp://app` origin, serves Brotli-compressed immutable assets from the binary,
and runs an external ES module without application-mode branching. The
headless async-service graph also compiles
through the fixed-point Z emitter: one reusable function sequences synchronous
and suspended service routes through two child-task suspension states. One
generated Notes binding runs through WebKit, and a narrow exported C entry
reaches the same handler directly for future zjs attachment. The AppKit
process/run-loop host remains a small Objective-C boundary. Phase 3 now has a
functional vertical slice in the ordinary configured application path: one
bundled ZJS source module starts after services, runs on its own native thread,
calls the same generated service API as a WebView through direct in-process Z
dispatch, enforces its immutable capability profile, restores typed runtime
errors, receives cooperative cancellation, joins before service shutdown, and
releases its engine through deterministic Z-owned control lifetime.

## Decision

Zapp's native core will be rewritten in Z.

Zapp is pre-production and has no compatibility obligation to existing users.
That makes this the right time to change architecture, APIs, and internal
representation where the result is clearer, safer, or more coherent. The
current Nim and Zen-C implementations are executable research and behavioral
references, not designs that the Z implementation must translate line by line.

The rewrite starts now, before Z implements every planned language feature.
Zapp is an intended real-world consumer of Z and should expose composition gaps
while those gaps remain inexpensive to fix.

## What "from scratch in Z" means

The rewrite creates a new Z-owned application core rather than transliterating
the existing native files. Z should ultimately own:

- application and shutdown lifecycle;
- window and webview identity;
- message decoding, routing, and typed service dispatch;
- worker ownership and coordination;
- permissions and capability enforcement;
- shared application state;
- platform-service contracts; and
- deterministic resource cleanup.

The TypeScript runtime, webview/worker bootstrap, frontend bindings, and
Bun/Vite-oriented build experience remain TypeScript initially. They execute in
the JavaScript ecosystem and are not native-core debt. The CLI can migrate later
if doing so provides a concrete distribution, performance, or maintenance win.

## Configuration boundary

`z.json` belongs exclusively to the Z language and package toolchain. Zapp does
not add framework-specific keys to it or depend on its unsettled internal
schema. Zapp owns `zapp.config.ts`, which is an ergonomic build-time authoring
surface for a web-oriented desktop framework.

The config may be either a typed object or a contextual `defineConfig` factory
that receives the command, mode, target OS/architecture/environment, and project
root. Regardless of how it is authored, the result must be plain serializable
data. The CLI validates and normalizes it into
`.zapp/config.resolved.json`; frontend building, native compilation, packaging,
and compiled application metadata consume that resolved contract rather than
re-evaluating application policy independently.

Executable configuration does not absorb runtime architecture. Services,
windows, menus, lifecycle behavior, and mutable application state stay in Z
source. The Z compiler does not evaluate or understand `zapp.config.ts`, and no
TypeScript configuration evaluator ships in the application binary. A future
static JSON authoring format can resolve to the same internal contract if a real
non-TypeScript consumer requires it.

Window source owns only a logical application-relative URL such as `/notes`.
The resolved configuration supplies the development origin and packaged asset
directory; the native backend supplies the packaged origin and transport.
Remote origins are a separate, explicit capability and do not receive the
privileged bridge by default.

## Repository and package ownership

The transition layout is not the final product architecture. `native/z/` keeps
the replacement isolated while the legacy implementation remains an executable
oracle, but the finished repository should make the Z framework—not its prior
art—the primary source tree. Nim, Zen-C, and superseded native code will
eventually move behind an explicitly named reference or legacy boundary before
being deleted when they are no longer needed for behavior and performance
comparison.

Rewriting the native core in Z does not imply removing every JavaScript package.
The browser bridge, generated TypeScript service clients, frontend bundler
integration, and a web-ecosystem CLI are legitimate companion tools. Their
current npm names, APIs, and package boundaries are not compatibility
contracts. The redesign may combine, split, internalize, or replace
`@zappdev/runtime`, `@zappdev/vite`, and `@zappdev/cli` wherever that produces a
smaller application surface, less configuration, better tree shaking, or a
clearer ownership boundary.

Perform the repository inversion once these facts are true:

1. the Z core is the default path for a representative application;
2. that application no longer links the legacy native implementation;
3. Z framework imports and the CLI-to-Z build contract are stable enough to
   survive a move without framework-local path conventions; and
4. current behavioral and performance baselines are recorded and repeatable.

Until then, additions should favor the Z implementation and avoid deepening
legacy directory or package assumptions. The eventual move is an architectural
checkpoint, not a cosmetic cleanup.

Objective-C, C, and C++ are dependencies and ABI surfaces, not implementation
languages Zapp must preserve. Z's checked imports and `.zd` contracts should
replace handwritten bridge code progressively. Small native shims remain valid
when an ABI cannot yet be represented honestly in Z, but they must be explicit
and tracked rather than becoming the new architecture.

## Product principles to preserve

The rewrite must retain the strongest ideas already proven by Zapp:

- system WebViews instead of a bundled browser;
- unusually small binaries and low idle memory;
- native windows, menus, dialogs, notifications, and platform behavior;
- one coherent frontend API across webviews and workers;
- direct worker-to-native calls without routing through a renderer;
- headless workers with application lifetime;
- zjs as the small, cross-platform first-party JavaScript engine;
- typed frontend bindings;
- platform escape hatches for applications that need native APIs; and
- measurable bridge, build-time, binary-size, and memory performance.

## What the Z architecture should improve

| Concern | Z rewrite direction |
|---|---|
| Application root | A stable readonly ARC `Application` publishes `Application.current()` for one guarded `run()` interval; synchronized `Once` lifecycle observation turns duplicate or post-shutdown publication into typed state errors while platform-private `Once` runtimes retain explicit initialization and shutdown. |
| Application quit | `app.quit()` and native OS termination converge on cancellable `app.events.quitRequested`; accepted requests unwind the ordinary run lifetime, while `run()` completion and `app.state()` remain the terminal signal. |
| Native lifetime | Owned values, `deinit`, ARC classes, `Weak<T>`, and checked foreign contracts replace implicit slot and callback lifetimes. |
| UI affinity | AppKit/UIKit work is isolated to `thread.main`; invalid access is rejected before generated native compilation. |
| Shared mutation | Prefer executor isolation; use `Mutex<T>.withLock` for state that genuinely crosses executors. |
| Message representation | JSON exists at the WebView boundary, then is decoded immediately into Z structs, enums, `Option`, and `Result`. |
| Errors | Internal failures use typed `throws`/`try`/`attempt`, not sentinel integers or loosely shaped error JSON. |
| Asynchrony | Structured tasks, scopes, cancellation, and explicit executor placement replace detached callback chains. |
| Native handles | Nominal owned or borrowed types express cleanup and escape rules; untyped integer/pointer handles do not leak through the core. |
| Callbacks | Target/action, delegates, blocks, and worker callbacks have compiler-visible ownership and executor provenance. |
| Shutdown | A deterministic shutdown phase joins children, stops workers, closes windows, releases engines, and then deinitializes the application root. |
| Engine boundary | Z exports a narrow C ABI where zjs and other engines require it; those exports remain ordinary callable Z functions internally. |

## Intended architecture

```text
Frontend application (TypeScript / chosen UI framework)
                    |
                    | system-WebView IPC
                    v
Bootstrap and @zappdev/runtime (TypeScript)
                    |
                    | JSON only at this boundary
                    v
Z application core
  - lifecycle and selected platform runtime
  - typed message protocol and router
  - services and permissions
  - windows, webviews, and events
  - worker registry and structured tasks
  - deterministic shutdown
          |                         |
          | checked native imports  | narrow exported C ABI
          v                         v
AppKit/UIKit/WebKit/...             zjs and optional worker engines
```

Platform modules implement common Z contracts. Cross-platform behavior should
be shared Z code; a platform branch should contain only behavior that is truly
platform-specific. macOS is the first implementation target, zjs is the first
worker engine, and one window plus one WebView is the first UI shape.

The first executable platform seam is now concrete. Portable
`Application.run()` prepares its generated metadata and services into
an immutable `PreparedApplication`, including the readonly process/path
`ApplicationContext`, creates the application `TaskScope`, then calls the single
selected `platform.zs` module. That module must export
the following contract:

```z
async function runApplicationPlatform(
  config: PreparedApplication,
  updates: TaskScope
): i32 throws ServiceLifecycleError on thread.main;
```
The current selector delegates to a private `MacOSApplicationRuntime`; a
headless smoke exports the same function while using a completely different
runtime shape. There is no runtime platform dispatch or common native storage
layout.

Z's fixed-point compiler executes constrained trait calls through direct static
dispatch, without a vtable or trait-object allocation. A framework-owned
generic method can specialize over an application-private downstream type, so
`ServiceLifecycleBuilder.register(name, service)` constructs its stored-callable
adapter internally. Z still does not provide trait-typed storage. Callable
types preserve `on thread.main`, aggregate affinity follows those stored
values, and off-main construction or invocation is rejected. Future
conditional-module selection plus target-matrix checking will compile this same
export contract for macOS, Windows, and Linux without changing the public
`Application` surface.

## Boundary rules

1. JSON does not become the internal object model. Parse once at ingress and
   encode once at egress.
2. A foreign pointer or framework reference must have explicit owned, borrowed,
   nullable, and cleanup semantics before it enters reusable safe Z code.
3. UI objects are main-executor-bound even when stored inside otherwise
   transferable Z values.
4. A callback adapter must be retained by an owner whose lifetime the compiler
   can relate to the native registration. Stack-frame luck is not ownership.
5. Detached work is exceptional. Application work belongs to an explicit task
   scope or owned task, with a cancellation and shutdown story.
6. Raw native code is a last-resort ABI escape. It must not become an alternate
   application architecture.
7. Every abstraction added to a hot path should be inspectable in generated C
   and measured against the current implementation.
8. Framework bootstrap injection and application-authored web-content
   injection are separate lifecycle layers. The bridge remains a deterministic
   document-start script. A future public injection surface must distinguish
   document-start scripts, document-end scripts, and styles, preserve ordering,
   avoid `eval`, and behave consistently across engines.

## Rewrite sequence

### Phase 0: establish the replacement track

- Keep the current implementation buildable as a behavioral and performance
  oracle while the first Z slice is incomplete.
- Build the new core under `native/z/` and select it explicitly during the
  transition (the existing `ZAPP_NATIVE_LANG` mechanism is sufficient).
- Record the Z compiler revision used by Zapp and make a compiler mismatch fail
  clearly.
- Preserve representative smoke tests and the current bridge/binary/build
  benchmarks before replacing their implementations.
- Promote the strict-C path in `spikes/z-notes/bridge.ts` into the framework build rather
  than treating the spike as permanent architecture.

Exit: the Z core builds and links through the ordinary Zapp CLI path without
changing the user frontend project.

### Phase 1: first end-to-end application

Implement one deliberately complete vertical slice:

1. initialize the Z embedding/runtime boundary;
2. consume the Z `Application` builder into the process-wide platform runtime;
3. start `NSApplication` and keep its run loop attached to Zapp's process
   lifetime;
4. create one `NSWindow` containing one `WKWebView`;
5. inject the existing document-start bootstrap;
6. receive one WebView message;
7. decode it into a typed Z message variant;
8. dispatch one typed service handler;
9. encode and deliver a response;
10. close the window, stop the run loop, and deterministically clean up every
    owned native and Z resource.

Exit: a frontend button completes a visible WebView -> Z -> WebView round trip,
the app remains alive until the window closes, and sanitizers report no leaks,
dangling callback targets, or ownership errors.

Steps 7-9 are proven independently of WebKit by the promoted native bridge:
`std/json` decodes `{t,id,m,a}`, `BridgeMessage` and `BridgeResponse` keep the
core typed, and the response metadata returns through a narrow C callback. The
visible executable uses that same router and service state in the real WebView
lifecycle.

The current visible transport checkpoint proves steps 2-10. Z owns the
executable `main` and constructs the public readonly ARC `Application`; its
async `run()` prepares service configuration, publishes the same application
identity through `Application.current()` for the blocking run-loop lifetime,
joins callback-created tasks, and releases the process root after shutdown. The
main-executor Z application creates and strongly owns the window, WebView,
configuration, content controller, retained `WKScriptMessageHandler`
registration owner, protocol adapter, and teardown guard. The Objective-C
platform adapter has no application entry point or framework policy; it keeps
weak access to those identities for run-loop coordination and deterministic
smoke-test callbacks. The interactive application leaves the real button under
user control and stays open until its window closes. A separate bounded mode
automatically exercises it and updates the DOM from the typed Z response through
the canonical production bootstrap's `bridge.invoke()` and `_onInvokeResult()`
path. Phase 1 has a bounded UBSan plus
Objective-C-zombie lifecycle check. Its ASan startup probe detects that the
current Apple sanitizer runtime can deadlock before `main`, kills that probe
after three seconds, and skips the application run rather than orphaning a
CPU-intensive process. Phase 1 still requires ASan on a compatible host or
equivalent leak evidence; run-loop orchestration and the smoke-test response
machinery remain the principal Objective-C scaffolding.

## Application ownership and focused modules

Zapp takes explicit inspiration from the
[Wails v3 Manager API](https://v3.wails.io/concepts/manager-api/), especially
its clear application-owned window and service lifecycles. The inspiration is
credited rather than copied indiscriminately: Zapp uses an application
capability when state truly belongs to one application, and focused modules
when an operation does not need that ownership.

Native Z window creation remains application-scoped:

```z
import { Application } from "zapp";
import { WindowOptions } from "zapp/window";

const app = new Application();
const mainWindow = try app.windows.create(WindowOptions({
  title: "Notes",
  url: "/notes",
}));
return try await app.run();
```

`app.windows` is not cosmetic namespacing. It owns the registry, identifiers,
pre-run registrations, dynamic realization, main-executor contract, last-window
policy, and deterministic shutdown. A global `Window.create(...)` would have
to find the current application through hidden process state and make calls
before initialization, after shutdown, and across isolated tests ambiguous.

The same application identity owns lifecycle observation. `app.quit()` is a
request rather than an immediate process exit, and
`app.events.quitRequested.subscribe(...)` may call `event.cancel()` while that
specific request is in flight. Native macOS quit requests use the same path;
once accepted, shutdown remains deterministic and is observed by awaiting
`app.run()`.

This does not make `Application` a universal manager container:

- application-owned registries and authority-granting lifecycles belong on
  `app`, initially `windows`, `services`, and `dialogs`;
- resource behavior belongs on its handle, such as `window.show()` and
  `window.close()`;
- types and options come from focused modules such as `zapp/window`; and
- stateless operating-system capabilities should prefer focused imports rather
  than automatically becoming `app.clipboard`, `app.shell`, or another manager.

The WebView TypeScript API follows its own asynchronous boundary instead of
mirroring native Z mechanically. A frontend may import named functions and
proxy handles:

```ts
import {
  createWindow,
  currentWindow,
  WindowEvent,
} from "@zappdev/runtime/window";

const current = currentWindow();
const resized = current.subscribe(WindowEvent.RESIZE, ({ size }) => {
  console.log(size.width, size.height);
});
const diagnostics = await createWindow({
  title: "Diagnostics",
  url: "/diagnostics",
});
```

An async factory represents IPC failure more honestly than `new Window(...)`,
which cannot await native realization. Native Z and frontend TypeScript should
feel native to their environments while preserving the same identities,
permissions, lifecycle, and generated contracts.

### Phase 2: make the core real

- Multiple window identities and lifecycle events.
- Typed service registration and dispatch.
- Permission checks before service execution.
- Error and cancellation propagation across the WebView boundary.
- Application-owned main-thread state plus synchronized transferable metadata.
- Explicit shutdown phases and cleanup ordering.

Exit: a small application uses ordinary Zapp frontend APIs without knowing the
native core was replaced.

Current checkpoint: the Z Notes application creates multiple native windows,
uses generated typed services with error and cancellation propagation, and
drives `show`, `hide`, `setTitle`, and `close` through ordinary frontend window
handles into the Z-owned manager. AppKit focus, blur, and resize callbacks now
flow through typed Z events into the matching WebView. The focused
`@zappdev/runtime/window` boundary deliberately exposes only this composed
surface, talks directly to the narrow bridge, and neither imports nor exposes
the legacy `Window` implementation. Its application-owned SQLite service now
loads, creates, edits, archives, and deletes notes through generated TypeScript
bindings. Native mutation errors retain their nominal Z identity and structured
details across the WebView boundary, while persistence is committed before the
main-thread catalog changes.

This satisfies the Phase 2 exit criterion for the macOS reference vertical
slice. Additional product breadth remains intentionally separate from the
replacement core proof.

### Phase 3: zjs worker vertical slice

- Initialize and own one zjs context from Z.
- Export the minimal C ABI that zjs host bindings require.
- Start one headless worker with application lifetime.
- Perform one direct typed worker-to-Z service call without WebView IPC.
- Cancel, join, and destroy the worker during application shutdown.

Exit: the defining Zapp worker fast path works end to end and retains its
performance advantage.

Current checkpoint: configured ZJS source modules now satisfy initialization,
application lifetime, cancellation, join, and destruction end to end in the Z
Notes smoke. The generated immutable catalog preserves each worker's expanded
capability, permission, service-method, engine, module, and restart evidence.
The first runtime deliberately executes only the source-module ZJS subset;
other engines and bytecode fail during the build instead of silently changing
semantics. A bounded private host-to-worker queue now proves command wakeup and
dispatch through an engine-neutral runtime vtable: the Z Notes worker smoke
queues `ping` before initialization and requires the worker's `pong` response.
The checked bridge now routes authorized frontend messages to configured
application workers, distinguishes unavailable, saturated, and failed dispatch,
and maps those outcomes into descriptive frontend errors. The focused
`@zappdev/runtime/worker` surface exposes `applicationWorkers.get(id)`, awaited
`send(channel, data)`, and explicitly disposable `subscribe(channel, handler)`
without exposing the legacy worker implementation. Worker messages return
through an arbitrary-thread Z callback, copy native bytes into owned Z strings,
hop onto the application main executor, publish through the configured
worker's multicast `messages` event source, and independently reach only
WebViews whose immutable capability profile grants that worker. Direct typed worker-to-Z
service invocation now uses the same generated `zapp:services` facade as a
WebView. The runtime selects direct in-process dispatch for a configured ZJS
worker and request/response IPC for a WebView without changing application
code. Synchronous methods stay on the minimal resolved-Promise path;
suspending methods retain a bounded native Promise capability, record the Z
`TaskControl`, and settle back on the owning worker thread. Cancellation
reaches that task and late completion is harmless. The Z Notes smoke proves an
authorized `health.status()` call, suspended `notes.isEmpty()`, cancellation,
and an ungranted `notes.create()` rejection before service code executes. The
post-continuation performance proof measures the direct ZJS-to-Z host path at a
399 ns median per call and the unchanged generated Promise API at a 2.253 us
median per sequential call on an Apple M4 Pro. This is intentionally
architectural evidence rather than a cross-framework score: the established
WebView no-op round trip is 79 us, so the direct worker path preserves the
expected order-of-magnitude advantage.

Configured restart policy is now executable in the replacement runtime. Each
uncaught failure destroys the failed engine context, cancels its pending native
service continuations, and creates a fresh context from the immutable embedded
module until `maxRetries` inside `withinMs` is exhausted. A dedicated Z Notes
smoke proves two replacements followed by terminal give-up without preventing
normal application teardown. Native Z now exposes configured handles through
`app.workers`, with typed state and send failures, focused lifecycle event
sources, and one exhaustive aggregate event. Lifecycle delivery hops from the
engine callback onto `thread.main`; subscription lifetime is explicit and
deterministic. This completes the Phase 3 reference vertical slice; dynamic
worker creation, WebView-owned worker lifetimes, additional engines, and
bytecode remain product-expansion work rather than exit blockers.

The current lifetime control uses a private engine-neutral native vtable behind
an opaque identity. Z still owns every control object, immutable restart
evidence, and the service/worker shutdown order; the ZJS adapter currently owns
the per-engine incarnation loop. This narrow seam exists because fixed-point
storage of imported generic channel endpoints and supervision of an
ownership-bearing `thread.spawn` task do not yet compose in the generated
application frame. The separate worker-host spike proves those channel and
direct-service behaviors; the incarnation loop should move back into ordinary
Z as those two general compiler tiers land.

### Phase 4: expand product surface

Grow from executable application needs rather than porting directory breadth:

- events and multiple workers;
- dialogs, menus, notifications, clipboard, and native UI;
- embedded WebViews and protocol handlers;
- security policies and filesystem boundaries;
- packaging and resources; and
- optional worker engines behind the common engine contract.

### Phase 5: additional platforms

- Share the typed application core across macOS and iOS first.
- Add Windows through WebView2 and native Windows contracts.
- Add Linux only after its WebView and packaging choices are explicit.
- Delete legacy Nim/Zen-C paths when the supported platform matrix no longer
  needs them as an oracle or fallback.

## Z language-gap workflow

Zapp must pressure-test Z without accumulating framework-local compiler
workarounds.

When the rewrite exposes a language or interop gap:

1. reduce it to the smallest representative fixture in the Z repository;
2. decide whether the gap is language semantics, `.zd` vocabulary, standard
   library, code generation, runtime, or editor tooling;
3. fix and test the general capability in Z;
4. update the Z compiler revision used by Zapp; and
5. resume the application slice using the normal language surface.

A permanent shim is justified only when the native ABI is inherently outside
Z's intended safe surface. The rewrite should not quietly design new Z syntax
inside Zapp.

## Known pressure points

| Area | Current evidence | Rewrite question |
|---|---|---|
| AppKit and main-thread work | The main-executor Z application creates and owns the window, WebView, configuration, content controller, and script handler; the visible round trip proves teardown. | Do navigation delegates, multiple windows, and broader callbacks compose cleanly? |
| ARC application state | `Application.run()` publishes the stable ARC application identity and owns a platform-private `Once<MacOSApplicationRuntime>` lifetime containing the native UI graph, protocol adapter, and registration guard while the Objective-C adapter holds weak references. | Can multiple application-owned native delegates avoid cycles and preserve deterministic shutdown? |
| Message protocol | Z has strings, collections, enums, matching, errors, and exported C functions. | Is JSON parsing/encoding production-ready and allocation-conscious at the bridge boundary? |
| Async and executors | A WebKit callback now submits owned messages through an application `TaskScope`; suspended Z services publish on main and shutdown cancels and joins accepted work. | Can per-request cancellation, richer errors, worker executors, and multiple windows preserve the same structured boundary? |
| zjs embedding | `export c function` and the message-bridge spike prove bidirectional linking; a configured bundled module starts, calls synchronous and suspended Z services directly through the same generated API used by WebViews, receives typed denials, propagates cancellation, restarts within a bounded policy, joins, and releases through the ordinary Z Notes lifecycle. The post-continuation probe measures 399 ns for the direct host path and 2.253 us through the generated Promise API on an Apple M4 Pro. | Can broader wire values, multiple engines, public lifecycle observation, and callback lifetimes preserve the same environment-neutral API without reducing every internal representation to JSON? |
| Worker supervision | Z owns immutable worker authority plus application-lifetime cancel/join controls; the engine adapter owns only its thread and context behind a private vtable. | When fixed-point generic channel storage and ownership-bearing thread-task joins land, can the temporary lifetime seam be replaced by the already-proven Z `Channel<T>` / worker-engine supervisor? |
| Resources and packaging | The existing CLI already bundles bootstraps, assets, and native sources. | What should the stable Z build/library contract be before the CLI depends on it? |
| Portability | Portable `Application` configuration now crosses one selected `runApplicationPlatform` module seam; macOS and headless implementations prove that private runtime layouts may differ. | When Windows pressure begins, which conditional-module and `std/target` spelling selects every implementation and checks the target matrix? |

## Performance gates

Measure the replacement against equivalent behavior in the current core:

- clean and incremental native build time;
- final binary and application bundle size;
- idle and one-window memory;
- WebView message round-trip latency;
- direct zjs worker-to-native call latency;
- allocations and copies per message;
- ARC retain/release activity on hot paths; and
- startup and deterministic shutdown time.

The goal is not merely to avoid regression. The Z rewrite should make safety
costs visible, allow the optimizer to remove language abstractions, and retain a
performance ceiling in the C/Rust/Zig class when semantics are comparable.

## First main-chat task

Start with Phase 0, not a broad port:

> Add an in-tree `native/z/` core selected by `ZAPP_NATIVE_LANG=z`. Build and
> link a Z static library through the normal Zapp CLI, initialize and shut down
> its exported runtime, and route the existing one-message spike through that
> framework-owned path. Preserve the current native core as the behavioral
> oracle until the Phase 1 WebView round trip is complete.

That checkpoint is intentionally narrow. Once it works, the next task is the
single-window `NSApplication` + `WKWebView` vertical slice described in Phase 1.
