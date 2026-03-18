Recommended architecture

I’d split into three layers.

1. Engine-agnostic worker runtime contract

This is the behavior your library promises to app developers. Workers can be created in two ways: (1) **webview-triggered** — `new Worker(url)` in the page posts a create action to the native backend (current “shadow” model); (2) **host-created** — e.g. `app.createWorker(scriptPath)` from Zen-C with no webview, same backend and bridge. Same contract either way; see WORKERS_PROTOCOL.md §7.

Things like:
	•	create worker
	•	create/reuse shared worker
	•	post message
	•	terminate
	•	reset owner
	•	reset all
	•	dispatch connect/disconnect
	•	deliver events to webviews
	•	shape worker errors consistently
	•	JSON payload conventions
	•	bridge method names

This should be defined once in shared code and treated as the spec.

2. Engine adapter layer

This is where JSC and QJS differ.

For example:
	•	create context
	•	evaluate bootstrap
	•	evaluate user script
	•	install native bridge methods
	•	call JS function
	•	stringify/parse values
	•	extract exception fields
	•	manage value ownership
	•	drain pending jobs
	•	teardown/GC

This layer should be very explicit:
	•	engine_jsc_*
	•	engine_qjs_*

3. Feature modules built against the engine adapter

Things like:
	•	timers
	•	fetch
	•	crypto

These should not know about “worker backend selection.” They should know only:
	•	“I am installing timer support into this engine context”
	•	“I can call this engine’s function callback”
	•	“I can report errors through this engine adapter”

That keeps feature behavior shared while engine glue stays separate.

⸻

What this means for file organization

I would move toward something like:
	•	worker.zc
	•	worker_common.zc
	•	worker_backend_jsc.zc
	•	worker_backend_qjs.zc

And then either:
	•	engine_jsc.zc
	•	engine_qjs.zc

plus feature modules:
	•	worker_timers_common.zc
	•	worker_timers_jsc.zc
	•	worker_timers_qjs.zc
	•	worker_fetch_common.zc
	•	worker_fetch_jsc.zc
	•	worker_fetch_qjs.zc
	•	worker_crypto_jsc.zc
	•	worker_crypto_qjs.zc

Or, if common logic is thin, just keep:
	•	worker_timers_jsc.zc
	•	worker_timers_qjs.zc
	•	etc.

The key design decision

Because QJS is production-default on Windows, I would not make JSC the “main” architecture and QJS the special case.

Instead:
	•	define the contract in shared/common code
	•	have JSC and QJS both conform to it

That keeps Windows from feeling bolted on.

⸻

Practical abstraction boundary

I would abstract these operations, conceptually at least:
	•	create context
	•	free context
	•	install global aliases (globalThis, self, dispatch id, bridge)
	•	install bridge functions
	•	eval bootstrap bytes
	•	eval worker source bytes
	•	call bridge method by name
	•	parse JSON string to engine value
	•	stringify engine value to JSON
	•	convert engine exception to normalized error payload
	•	drain engine jobs/microtasks

If you have these operations, then most of:
	•	create
	•	post
	•	terminate
	•	shared worker reuse
	•	reset owner
	•	reset all

can be mostly the same structurally across engines.

⸻

What I would not over-abstract

I would avoid trying to make a super-generic macro-heavy layer that hides everything.

For example, I would not try to force these into one implementation file:
	•	JSC value ownership
	•	QJS JS_DupValue/JS_FreeValue
	•	JSC exception model
	•	QJS pending jobs
	•	JSC native blocks vs QJS C callbacks

That usually becomes harder to maintain than two explicit adapters.

So the right level is:
	•	shared flow
	•	separate engine primitives

not:
	•	one mega-file with #ifdef everywhere

⸻

Windows implication

Because Windows will always use QJS, I’d make sure the QJS path has:
	•	the cleanest lifecycle code
	•	the best tests
	•	the clearest module boundaries
	•	the strongest stress coverage

In other words, QJS should probably be the backend you optimize your architecture around, with JSC as the alternate engine that conforms to the same contract.

That does not mean designing around QJS quirks. It means making the abstractions strong enough that QJS is not second-class.

⸻

My recommendation

I’d organize the code around this principle:

One worker model, two engine adapters.

Concretely:
	•	keep one shared conceptual worker/shared-worker lifecycle
	•	isolate engine operations in JSC/QJS adapters
	•	keep timers/fetch/crypto as feature modules with engine-specific implementations where needed
	•	make QJS a first-class production runtime, not a special opt-in path

⸻

Contract as superpower

The real payoff of a clear contract is **pluggable engines**. If the worker runtime is defined as:

	•	a fixed wire protocol (actions + payload shapes)
	•	a fixed engine interface (create context, eval, call, stringify, drain jobs, etc.)
	•	a fixed app-facing API (create, post, terminate, shared worker, events)

then **any** JS engine that can implement that interface can run Zapp workers. We ship JSC (macOS) and QJS (macOS + Windows) today, but the same contract could be implemented by:

	•	Moddable XS (small footprint, embedded)
	•	MuJS (lightweight, embeddable)
	•	V8 (if we ever wanted Chromium-style workers on a platform)
	•	other engines we don’t know about yet

We don’t have to support them officially. The point is: the architecture is “one worker model, N engine adapters.” The contract is the spec. New engines conform to it; the app and the wire protocol don’t change. That’s the superpower.

⸻

Refactor plan

**0. Scaffold (done)**

	•	`WORKERS_PROTOCOL.md` — Wire protocol, payload shapes, bridge method names, engine interface, lifecycle. Single source of truth.
	•	`worker_common.zc` — Placeholder for shared flow; not yet imported. Current flow remains in worker_jsc.zc / worker_qjs.zc.
	•	`engine_jsc.zc`, `engine_qjs.zc` — Placeholders for engine adapter; not yet imported. Current implementation stays in worker_jsc.zc / worker_qjs.zc. Reference these when moving engine ops in Phase A.

**1. Document the contract (single source of truth)**

	•	**Wire protocol** — In this doc or a short `WORKERS_PROTOCOL.md`, list:
		- Action names: `create`, `post`, `terminate`, `reset_owner`, `reset_all`, etc.
		- Payload shapes per action (e.g. create: `{ id, scriptUrl, ownerId?, shared? }`; post: `{ workerId, data, targetId? }`).
		- Bridge method names the bootstrap expects: `postMessage`, `emitToHost`, `dispatchMessage`, `deliverEvent`, etc.
	•	**Engine interface** — The operations any adapter must provide (see “Practical abstraction boundary” above). Treat this as the API for “implementing a worker engine.”
	•	**Lifecycle states** — When a context is created, when it’s registered, when it’s torn down, and what “reset owner” / “reset all” do to the map.

TS bootstrap and native backends both implement the wire protocol; new engines implement the engine interface.

**2. Split engine vs backend**

	•	**Engine** = low-level VM wrapper only:
		- create/free context, eval bytes, call function, value ↔ JSON, exception → normalized payload, drain jobs.
		- No worker id, no shared-worker state, no context map.
	•	**Backend** = worker/shared-worker lifecycle:
		- Context map, shared-worker reuse, create/post/terminate/reset.
		- Calls only the engine interface; no direct JSC/QJS calls in backend flow.
	•	Feature modules (timers, fetch, crypto) depend on the **engine** interface, not the backend. That keeps them testable and reusable.

**3. File layout (phased)**

	•	**Phase A** — Introduce without moving everything:
		- Add `WORKERS_PROTOCOL.md` (or a “Contract” section here) with wire protocol + engine interface.
		- Add `engine_jsc.zc` / `engine_qjs.zc` that expose the engine operations; backends call into them. Optionally keep current backend files as thin wrappers that delegate to engine + common flow.
	•	**Phase B** — Extract feature modules:
		- `worker_timers_jsc.zc`, `worker_timers_qjs.zc` (and similarly fetch, crypto). Each gets “install into context” and uses only engine interface. Backends wire them in when creating a context.
		- Add `_common.zc` for a feature only when duplication is real (e.g. timer ID and interval logic).
	•	**Phase C** — Shared flow in one place:
		- `worker_common.zc` (or equivalent) holds the structural flow for create/post/terminate/reset; backends supply engine and feature hooks. No engine-specific branches in that flow.

**4. Keep the contract stable**

	•	When adding a new action or bridge method, update the protocol doc first, then TS and native.
	•	When adding a new engine (e.g. XS or MuJS), add a new engine adapter and feature impls; contract and wire protocol stay the same.

⸻

**Current status: feature parity**

Both engines support the same worker bridge API:

| Feature   | JSC | QJS |
|----------|-----|-----|
| Timers   | ✓ `worker_timers.zc` (shared module) | ✓ inline in `worker_qjs.zc` |
| Fetch    | ✓ `worker_fetch.zc` (shared module)  | ✓ inline in `worker_qjs.zc` |
| Crypto   | ✓ `worker_crypto.zc` (shared module)  | ✓ inline in `worker_qjs.zc` (getRandomValues, randomUUID) |

JSC uses the three shared modules (they depend on `JSContext`/Obj-C). QJS has equivalent behavior implemented inline in `worker_qjs.zc` because those modules are JSC-specific. Phase B would extract QJS feature code into `worker_timers_qjs.zc`, `worker_fetch_qjs.zc`, `worker_crypto_qjs.zc` so the layout matches the “feature modules per engine” plan and logic isn’t duplicated in one large file.

⸻

Where to start implementation

Start with **Phase A, Step 1**: extract the smallest engine slice so the backend calls into the engine instead of inlining VM ops. No behavior change; just a clear boundary.

**Step 1a — JSC engine: context lifecycle + eval**

	•	**engine_jsc.zc** (implement and wire into the build):
		- `engine_jsc_create_ctx(vm, name)` → create JSContext, return opaque pointer. No globals, no bridge, no exception handler; backend sets those after.
		- `engine_jsc_eval(ctx, utf8Bytes, byteLen, filename)` → evaluate script; return 0 on success, -1 on error.
		- `engine_jsc_get_exception_message(ctx)` → return last exception message (for error reporting after failed eval).
		- `engine_jsc_free_ctx(ctx)` → release the context.
	•	**worker_jsc.zc** (minimal change):
		- In the create path, replace direct `[[JSContext alloc] initWithVirtualMachine:...]` with `engine_jsc_create_ctx(zapp_worker_vm, ...)`.
		- Replace the two `evaluateScript:` calls (bootstrap + wrapped user script) with `engine_jsc_eval(ctx, utf8, len, filename)`; on -1, use `engine_jsc_get_exception_message` and dispatch error to webview.
		- On terminate, call `engine_jsc_free_ctx(ctx)` (or equivalent) instead of releasing the context directly.
	•	Keep in worker_jsc: VM singleton, exception handler, globals (globalThis, self, __zappWorkerDispatchId, __zappBridge), bridge method blocks, timers/fetch/crypto init, context map, shared-worker logic. So the first slice is only “create context / eval bytes / free context” behind the engine.

**Step 1b — QJS engine: same slice**

	•	**engine_qjs.zc**: Same four operations (create_ctx, eval, get_exception_message, free_ctx) for QuickJS. Implement with qjs_rt, JS_NewContext, JS_Eval, JS_GetException + JS_ToCString, JS_FreeContext.
	•	**worker_qjs.zc**: In the create path (inside the dispatch_async block), use engine_qjs_create_ctx / engine_qjs_eval / engine_qjs_get_exception_message; on terminate, engine_qjs_free_ctx. Leave everything else (bridge, timers, fetch, console, shared-worker, script loading via NSURLSession) in worker_qjs.

**Build**

	•	Wire engine_jsc.zc into the Darwin build when JSC is selected (engine_jsc.zc is imported by worker_jsc.zc or by worker.zc conditionally). Wire engine_qjs.zc when QJS is selected. Ensure worker_jsc.zc and worker_qjs.zc still compile and the example app runs with both backends.

**After Step 1**

	•	You have a clear engine boundary: create, eval, exception message, free. Next slices can move “install globals”, “install bridge”, “call bridge method”, “drain jobs” into the engine adapters so the backend becomes pure lifecycle + routing. Then Phase B (feature modules) and Phase C (shared flow in worker_common) can follow.