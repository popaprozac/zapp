# Worker wire protocol and contract

Single source of truth for the worker runtime. TS bootstrap and native backends both implement this; new engines conform to the engine interface.

---

## 1. Wire protocol (webview → native)

Messages are sent via the platform bridge. Channel/key is `"worker"`. Payload is a JSON string. The native side parses it and dispatches on `action`.

### 1.1 Action names

| Action         | Description                                      |
|----------------|--------------------------------------------------|
| `create`       | Create a new worker (or attach to shared worker) |
| `post`         | Deliver a message to a worker                    |
| `terminate`    | Terminate a worker                               |
| `reset_owner`  | Terminate all workers for an owner               |

(There is no `reset_all` action from the webview; the host may call it when closing the app or last window.)

### 1.2 Payload shapes

**Common fields (when applicable)**

- `id` or `workerId` (string): worker instance id. Required for create, post, terminate.
- `ownerId` (string, optional): window/owner id for lifecycle (e.g. terminate workers when window closes).
- `shared` (boolean, optional): if true, create/reuse shared worker by scriptUrl.

**`create`**

```json
{
  "id": "<worker-id>",
  "scriptUrl": "<absolute URL to worker script>",
  "ownerId": "<optional>",
  "shared": false
}
```

- `scriptUrl` must be loadable by the native side (http(s) or file URL). Blob URLs are not loadable unless the host sends script content by another path (TBD).
- If `shared` is true and a context already exists for `scriptUrl`, the backend attaches the new `id` to that context and calls `dispatchConnect(id)`; it does not load or eval the script again.

**`post`**

```json
{
  "id": "<worker-id>",
  "data": <any JSON-serializable value>,
  "ownerId": "<optional, for auth>"
}
```

- Backend looks up the context for `id`, gets the bridge, calls `dispatchMessage(data, id)` (or equivalent). `data` is the parsed object.

**`terminate`**

```json
{
  "id": "<worker-id>",
  "ownerId": "<optional, for auth>"
}
```

- Backend removes the worker from the context map, cancels timers/fetch for that id, and if the context is not shared (or refcount goes to 0), frees the context. For shared workers, it decrements refcount and only frees when 0.

**`reset_owner`**

```json
{
  "ownerId": "<owner-id>"
}
```

- Backend terminates every worker whose `ownerId` matches. No `id` in payload.

---

## 2. Native → webview delivery

The native side delivers worker events to all webviews by evaluating JS that calls:

- `globalThis[Symbol.for('zapp.bridge')].dispatchWorkerBridge(kind, workerId, payloadJson)`

**Kinds**

| Kind      | Meaning                          | `payloadJson`        |
|-----------|----------------------------------|----------------------|
| `message` | Worker posted to main (or target)| JSON string of data  |
| `error`   | Worker script/runtime error      | `{"message":"..."}`  |
| `close`   | Worker closed                     | `"{}"`               |

The webview bridge then routes these to the correct worker handle and emits `message` / `error` / `close` events to app code.

---

## 3. Bridge methods (native installs on worker context)

The bootstrap expects a bridge object (e.g. `globalThis[Symbol.for('zapp.bridge')]`) with these methods. The **engine adapter** is responsible for installing them and implementing the native side.

| Method            | Purpose |
|-------------------|--------|
| `postMessage(data, targetId?)`   | Worker → webview: send message (targetId optional for directed post). |
| `emitToHost(name, payload)`     | Worker → host: emit app-level event. |
| `invokeToHost(method, payload)` | Worker → host: invoke a host method. |
| `reportError(error)`            | Report uncaught error to webview (error kind). |
| `closeWorker()`                 | Worker requests close (webview receives close kind). |
| `dispatchConnect(id)`           | Called by native when a new client connects to a shared worker (id = new client id). |
| `dispatchDisconnect(id)`        | Called when a client disconnects (optional). |
| `dispatchMessage(data, sourceId?)` | Called by native when a message is posted to this worker (post action). |
| `setTimer(fn, ms, repeat)`      | Returns timer id. |
| `clearTimer(id)`                | Cancel timer. |
| `fetch(url, options, resolve, reject)` | Native fetch; resolve/reject are callbacks. |
| `getRandomValues(array)`        | Crypto.getRandomValues. |
| `randomUUID()`                  | Crypto.randomUUID. |

**Globals the bootstrap expects before eval**

- `globalThis` → global object
- `self` → global object
- `__zappWorkerDispatchId` → string (worker id for this context)
- `__zappBridge` → bridge object (bootstrap may move it to `Symbol.for('zapp.bridge')`)

---

## 4. Engine interface (for adapter implementation)

Any engine (JSC, QJS, XS, MuJS, …) that wants to run Zapp workers must support these operations. The **backend** (worker lifecycle) uses only this interface; it does not call engine-specific APIs directly.

- **create context** — Allocate a new JS context/runtime for a worker.
- **free context** — Tear down and free the context (and any engine-specific resources).
- **install global aliases** — Set `globalThis`, `self`, `__zappWorkerDispatchId`, `__zappBridge` on the global object.
- **install bridge functions** — Register the bridge methods above (engine-specific: native blocks, C callbacks, etc.).
- **eval bootstrap bytes** — Run the bootstrap script (UTF-8 bytes) in the context.
- **eval worker source bytes** — Run the user script (wrapped as needed, e.g. async IIFE) in the context.
- **call bridge method by name** — Given a method name (e.g. `dispatchMessage`) and arguments (as engine values or serialized), call the method on the bridge object.
- **parse JSON string → engine value** — So the backend can pass `post` data into the engine.
- **stringify engine value → JSON** — So the backend can send worker output to the webview.
- **convert engine exception → normalized error payload** — e.g. `{"message":"..."}` for `error` kind.
- **drain engine jobs / microtasks** — Run pending promises/jobs after eval or after calling into the context (so that async worker code and timers run).

Feature modules (timers, fetch, crypto) are implemented per engine but depend only on this interface (e.g. “call this function”, “install this callback”) and do not depend on the backend’s context map or shared-worker logic.

---

## 5. Lifecycle states

- **No context** — Worker id not in the backend’s context map.
- **Active** — Worker id is in the map; context exists; timers/fetch may be registered.
- **Shared, attached** — Same context is in the map under multiple worker ids (shared worker); refcount ≥ 1.
- **Terminated** — Backend removed the id from the map, cancelled timers/fetch for that id, and if the context was dedicated (or shared refcount 0), freed the context.

**reset_owner** — For every worker id whose `ownerId` matches, transition to Terminated.

**reset_all** — For every worker id, transition to Terminated (used when closing the app or last window).

---

## 6. Error payload shape

All worker errors delivered to the webview (error kind) should use a consistent shape so the app can show them:

```json
{
  "message": "Human-readable error string"
}
```

Optional future fields: `stack`, `filename`, `line`, `column`. Engine adapters should at least set `message` from the exception.

---

## 7. Creation paths: webview vs host (headless)

The same worker contract can be satisfied from two different **creation paths**. The backend should not assume workers are only created by the webview.

### 7.1 Webview-triggered (current)

- App code in the **webview** runs `new Worker(url)` or `new SharedWorker(url)`.
- The webview bridge posts a `create` action (with `id`, `scriptUrl`, `ownerId`, `shared`) to the native side.
- The native backend creates a JS context (JSC/QJS), loads the script, installs the bridge, and runs the bootstrap + user script.
- The worker’s bridge (e.g. `@zapp/runtime`) is available inside that context: `Events`, `Window`, `postMessage`, `fetch`, etc. Messages and events are delivered to/from the webview.

So today we **shadow** the browser’s Worker/SharedWorker: the webview is the trigger, but the real execution is in a native “backend” context.

### 7.2 Host-created (headless / script-driven)

- **No webview** is required. The host (e.g. Zen-C) creates a worker directly, e.g.:
  - `worker = app.createWorker("./some-script.ts")` (or a path the build toolchain resolves).
- The host uses the same backend (same engine, same create flow): allocate context, load script (path or URL resolved by host/build), install bridge, eval bootstrap + user script.
- The worker gets the **same** bridge and runtime surface. From inside the worker, `Window.create()`, `Events.emit()`, `fetch`, etc. all go through the same bridge to the host. So you can run an app “headless” (no windows) and still have the worker create windows or do work via the bridge.

Implications:

- **One contract** — Whether the worker was created by the webview or by the host, it’s the same engine, same bridge methods, same lifecycle. Only the *creator* and *delivery targets* differ (e.g. for host-created workers, “message” might be delivered to the host or to other workers instead of to a webview).
- **Headless run** — Start the app with zero windows; create one or more workers via `app.createWorker(scriptPath)`. The build toolchain handles resolving the script and injecting it. Those workers can then call `Window.create()` through the bridge, so the “app” can be driven entirely from a headless JS context.
- **API opportunity** — Expose the Zapp “backend” to app authors: the same Worker/SharedWorker-style runtime and bridge are available whether the worker was spawned by the webview or by the host. A first-class host API like `app.createWorker(scriptPath)` makes headless and script-driven flows natural without special-casing.

When implementing the engine/backend split, creation should be a single code path that accepts (workerId, scriptUrlOrPath, ownerId?, shared?) and optional delivery target (webview vs host). The wire protocol in §1 describes the **webview → native** path; the host-created path uses the same backend create flow with parameters supplied by the host instead of from a bridge message.
