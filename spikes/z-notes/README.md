# Z Notes application spike

This is the first Zapp project whose application-owned Z source is physically
separate from the reusable framework. It is intentionally still a spike: the
runtime behavior is real, while package-resolved `zapp` imports remain
productization work.

## The end-user application

An application author currently owns seven files under `zapp/`:

```text
zapp/
├── z.json            # editor/native header and deployment context
├── main.zs           # desktop entry and Application configuration
├── embedded.zs       # strict-C embedding entry used by the regression host
├── notes-core.zs     # shared model, behavior, and checked wire conversion
├── notes-service.zs  # suspending service and lifecycle adapter
├── health-service.zs # sync-only value service
└── sync-notes-service.zs # allocation-lean strict-C adapter
```

The ordinary desktop entry is deliberately small:

```z
import { createNotesService } from "./notes-service.zs";
import { createHealthService } from "./health-service.zs";
import { Application } from "../../../native/z/framework/application.zs";
import { WindowOptions } from "../../../native/z/framework/window.zs";
import { thread } from "std/thread";

async function main(): i32 on thread.main {
  let app = Application();
  app.services.register("notes", createNotesService());
  app.services.register("health", createHealthService());
  const mainWindow = app.windows.create(WindowOptions({
    title: "Z Notes",
    width: 720,
    height: 460,
  }));
  return match (attempt await app.run()) {
    success(status) => status;
    failure(_) => 70;
  };
}
```

`WindowOptions` is an ordinary value struct with defaults. `create` returns a
shared `Window` identity immediately and the manager retains every open window.
The first macOS native tier realizes one window registered before `run`; title,
size, visibility, and resizability reach AppKit. `Window.show()`, `hide()`,
`setTitle()`, and idempotent `close()` are main-executor operations. Native
multi-window and dynamic creation are the next window-runtime slice rather than
hidden behavior in this first checkpoint.

The repository-relative framework import is temporary. A real package/module
resolver should make it an ordinary stable Zapp import without copying runtime
sources into an application. The build stages the app and framework into one
isolated workspace today so the fixed-point compiler and editor inspect the
same source graph.

This spike now builds and runs through Z's fixed-point native driver. Manual
`TaskScope` construction, owned capture transfer, main-executor placement, and
scope close/join all execute without a Stage 0 override.

`NotesCore` is a normal readonly ARC class with synchronized state and owns the
single implementation of `create`, `count`, JSON decoding, and JSON encoding.
`NotesService` is the application-owned service. Its public `create` and
`count` methods are the frontend API. `count` is a real main-executor `async`
method, while `create` is synchronous Z; generated TypeScript bindings expose
both service invocations uniformly as cancellable promises. The build now
generates and installs its checked `AsyncService` dispatcher plus lifecycle
forwarder into the isolated staged application. The original `main.zs` remains
unchanged. One `register` call derives the async dispatcher and lifecycle
forwarder from the same service identity; the application does not register the
service twice. `NotesService` has no author-facing `invoke()` or `AsyncService`
conformance. Framework methods are excluded from generated TypeScript
bindings. The framework owns the registered service name and method-prefix
routing; the service does not repeat a route list, capture its registration
name, or construct a binding object.

`HealthService` is a sync-only value struct registered through the same API.
Its generated adapter implements the non-task `Service` path, and the WebView
smoke calls `health.status()` after the async Notes flow. This proves automatic
adapter selection without charging synchronous services task overhead.

The strict-C embedding entry uses `SyncNotesService`, a thin synchronous
adapter around the same `NotesCore`. This keeps that host from importing task
runtime code merely to exercise direct native invocation. It is a transport
boundary, not a second implementation of the Notes domain.

The cancellable `count` request genuinely suspends through scheduler-aware
`delay`. The
WebKit callback transfers its owned message into the application's `TaskScope`,
which keeps the operation structured until the response is delivered on
`thread.main`. A standard browser `AbortSignal` rejects the frontend request
immediately and requests cancellation of the corresponding Z task. If native
work wins the completion race, its late response is ignored rather than
published. Closing the application rejects new submissions, cancels and joins
accepted work, and only then runs service stop hooks.

## The reusable framework

The code an application should not own now lives under:

```text
native/z/framework/
├── application.zs
├── application-contract.zs
├── application-error.zs
├── application-services.zs
├── window.zs
├── services.zs
├── service-contract.zs
├── async-services.zs
├── async-service-contract.zs
├── async-bridge.zs
├── service-lifecycle.zs
├── service-lifecycle-contract.zs
├── bridge.zs
├── bridge/
└── platform/
```

This layer owns application lifecycle, frozen service routing, bridge envelope
decoding, typed outcomes, AppKit/WebKit identity, and deterministic shutdown. It
has no dependency on `NotesService` or any other application type.

## Run it

From the repository root:

```sh
bun run spike:z-notes
```

The visible macOS app stays open until its window is closed. Click **Create a
note in Z** to call the generated `notes.create` TypeScript binding and display
the returned native-service value in the DOM. **Cancel a suspended request**
starts `notes.count`, aborts it with a standard `AbortController` while the
service is yielded, and then proves a later request still succeeds. Expected
evidence after creating a note directly:

```text
Notes: notes service started
visible WebView round trip window=1 request=1 ok=true payload={"id":"1","title":"WebView note"}
Notes: notes service stopped
```

`zapp/z.json` gives direct editor analysis and `z check` the same macOS 14,
AppKit, WebKit, CoreFoundation, and project-header context used by the staged
Zapp build. The Zapp CLI still owns final host-library generation and linkage.

For a bounded automated round trip that aborts request 1, proves any raced
native response cannot publish stale state, completes request 2, and then
closes on success:

```sh
bun run spike:z-notes:smoke
```

The same app can be embedded behind the focused strict-C host:

```sh
bun run spike:z-bridge
```

That route proves direct service invocation, runtime initialization/shutdown,
non-ASCII JSON, and `u64.max` request identity without WebView involvement.

The bounded sanitizer pass remains available as:

```sh
bun run spike:z-webview:sanitize
```
