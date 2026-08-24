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
frozen typed service router. One generated Notes binding runs through WebKit,
and a narrow exported C entry reaches the same handler directly for future zjs
attachment. The AppKit process/run-loop host remains a small Objective-C
boundary.

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
| Application root | Consuming `Application.run(move this)` publishes one platform-private `Once` runtime with explicit initialization and shutdown. |
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
`Application.run(move this)` freezes its services into an
`ApplicationConfig`, freezes its explicit lifecycle registry separately, then
calls the single selected `platform.zs` module. That module must export
the following contract:

```z
function runApplicationPlatform(
  config: ApplicationConfig
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
- Promote `spikes/z-message-bridge/` evidence into the framework build rather
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
executable `main` and constructs the public consuming `Application` builder; its
`run(move this)` freezes service configuration, publishes the process root for
the blocking run-loop lifetime, and releases it after shutdown. The
main-executor Z application creates and strongly owns the window, WebView,
configuration, content controller, retained `WKScriptMessageHandler`
registration owner, protocol adapter, and teardown guard. The Objective-C
platform adapter has no application entry point or framework policy; it keeps
weak access to those identities for run-loop coordination and deterministic
smoke-test callbacks. The page automatically
exercises a real button and updates its DOM from the typed Z response through
the canonical production bootstrap's `bridge.invoke()` and
`_onInvokeResult()` path. Phase 1 has a bounded UBSan plus
Objective-C-zombie lifecycle check. Its ASan startup probe detects that the
current Apple sanitizer runtime can deadlock before `main`, kills that probe
after three seconds, and skips the application run rather than orphaning a
CPU-intensive process. Phase 1 still requires ASan on a compatible host or
equivalent leak evidence; run-loop orchestration and the smoke-test response
machinery remain the principal Objective-C scaffolding.

### Phase 2: make the core real

- Multiple window identities and lifecycle events.
- Typed service registration and dispatch.
- Permission checks before service execution.
- Error and cancellation propagation across the WebView boundary.
- Application-owned main-thread state plus synchronized transferable metadata.
- Explicit shutdown phases and cleanup ordering.

Exit: a small application uses ordinary Zapp frontend APIs without knowing the
native core was replaced.

### Phase 3: zjs worker vertical slice

- Initialize and own one zjs context from Z.
- Export the minimal C ABI that zjs host bindings require.
- Start one headless worker with application lifetime.
- Perform one direct typed worker-to-Z service call without WebView IPC.
- Cancel, join, and destroy the worker during application shutdown.

Exit: the defining Zapp worker fast path works end to end and retains its
performance advantage.

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
| ARC application state | `Application.run(move this)` owns a platform-private `Once<MacOSApplicationRuntime>` lifetime containing the native UI graph, protocol adapter, and registration guard while the Objective-C adapter holds weak references. | Can multiple application-owned native delegates avoid cycles and preserve deterministic shutdown? |
| Message protocol | Z has strings, collections, enums, matching, errors, and exported C functions. | Is JSON parsing/encoding production-ready and allocation-conscious at the bridge boundary? |
| Async and executors | Tasks, scopes, cancellation, placement, and native threads have working slices. | Can WebKit callbacks, task suspension, main-thread resumption, and shutdown cancellation compose in one app? |
| zjs embedding | `export c function` and the message-bridge spike prove bidirectional linking. | Can JS values and callback lifetimes cross efficiently without reducing everything to JSON? |
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
