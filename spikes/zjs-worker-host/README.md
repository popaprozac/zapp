# ZJS worker-host proof

This private spike validates the engine boundary for the Z rewrite of Zapp
Workers without committing a public `Worker` API.

The checked Z program lives under `native/z/smokes/zjs-worker-host` beside the
framework code it pressure-tests. The spike directory retains only the native
ZJS adapter, build runner, and editor manifest. Its generated standalone build
uses an exported smoke-only registration marker without exposing a public
Zapp Worker API or weakening package-scoped `internal` declarations.

It proves that:

- Z owns the move-only lifetime of an opaque ZJS engine adapter;
- the engine runs on a dedicated `thread.spawn` worker and is joined;
- an embedded ES module is evaluated through ZJS's stable C embedding ABI;
- Z owns the worker loop, sleeps until ZJS's next wake, and pumps a real timer;
- a bounded typed Z channel transfers owned `channel` + serialized `payload`
  envelopes into the running worker with ownership safety and backpressure;
- cooperative cancellation is separate from ordinary worker commands;
- JavaScript registers a named `add` receiver and replies through the distinct
  `added` channel, proving bidirectional worker messages rather than a fixed
  function-shaped command;
- JavaScript calls a checked `export c function` implemented in Z directly;
- that narrow host binding enters a generated typed `WorkerProbeService.add`
  adapter through Zapp's frozen Z `Services` router;
- the typed `i32` result returns through ZJS as a serialized named-channel
  response without WebView IPC (the private service adapter owns its generated
  JSON wire codec); and
- lexical Z cleanup destroys the ZJS context after the worker completes.

Run from the Zapp repository root:

```sh
bun run spike:zjs-worker-host
```

By default the runner expects sibling `z-lang` and `zjs` repositories. Set
`ZAPP_Z_REPO` or `ZAPP_ZJS_REPO` to override either location. The runner uses
`zjs/build/libzjs.a`, building the minimal tier when it is absent. ZJS pins its
compatible Zen-C compiler revision; `ZAPP_ZC` and `ZAPP_ZC_ROOT` can point the
runner at that compiler and source tree. `ZAPP_ZJS_LIBRARY` can instead select
an already-built static archive.

The checked-in `z.json` beside `native/z/smokes/zjs-worker-host/main.zs`
supplies stable header discovery to the Z language server. The runner emits a
private manifest with resolved library paths for the actual executable build.

This adapter is intentionally narrow. It keeps `ZjsContext`, `ZjsValue`, GC
roots, module evaluation, and engine error conversion out of Zapp's eventual
public worker model. The spike now imports Zapp's private generic
`WorkerEngine<Command>` runtime from `native/z/framework/worker/engine.zs`.
That contract is engine-neutral and command-neutral: load a module, dispatch
one application-selected command type, report pending work and its next wake,
pump one turn, and expose a lifecycle status. The temporary `WorkerCommand`
and `WorkerResponse` envelopes live in the private framework worker layer so
the configured-worker implementation and this deeper channel proof share one
shape. They are not public Zapp API. This is executable evidence for a future
API, not that API itself.

The embedded JavaScript deliberately mirrors the product vocabulary being
pressure-tested:

```ts
worker.receive("add", (payload) => {
  worker.send("added", result);
});
```

The current transport serializes payloads as JSON text. Structured-clone and
binary transfer are later transport tiers; neither is implied by this proof.

The private mailbox uses `Channel<WorkerCommand>.bounded(capacity)` with a
shareable asynchronous sender and one synchronous receiver owned by the worker
thread. Sending applies backpressure without blocking the async executor. The
worker blocks only when it has no JavaScript work to pump. Cancellation remains
a separate operation: it records cancellation state and closes the command
sender, which wakes a worker blocked in `receive()`.

This is deliberately not yet a general event loop. The first tier processes one
command until the embedded engine becomes quiescent, then receives the next.
Waking on either concurrent command arrival or an engine timer will eventually
require a native wait-set/selection primitive or an async executor hosted by the
worker thread. The spike records that pressure without prematurely adding
`tryReceive` or a channel-specific polling API to Z.
