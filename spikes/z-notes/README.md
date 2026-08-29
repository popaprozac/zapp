# Z Notes application spike

This is the first Zapp project whose application-owned Z source is physically
separate from the reusable framework. It is intentionally still a spike: the
runtime behavior is real, and Z's exact project import map now provides the
intended public `zapp` module names. Package installation and version selection
remain productization work.

## The end-user application

An application author currently owns the Z application modules under `zapp/`
and an ordinary Vite frontend under `frontend/`:

```text
zapp/
├── z.json            # Zapp package dependency plus native/deployment context
├── main.zs           # desktop entry and Application configuration
├── embedded.zs       # strict-C embedding entry used by the regression host
├── notes-core.zs     # shared model, behavior, and checked wire conversion
├── notes-service.zs  # suspending service and lifecycle adapter
├── health-service.zs # sync-only value service
└── sync-notes-service.zs # allocation-lean strict-C adapter
frontend/
├── index.html        # Vite frontend entry
├── app.js            # application ES module and generated-service consumer
└── injected/         # build-checked per-window injection profile evidence
vite.config.ts        # frontend/ -> dist/ production build
zapp.config.ts        # Zapp metadata and packaged dist/ asset root
```

The ordinary desktop entry is deliberately small:

```z
import { createNotesService } from "./notes-service.zs";
import { createHealthService } from "./health-service.zs";
import { Application } from "zapp";
import { WindowOptions } from "zapp/window";
import { thread } from "std/thread";

async function main(): i32 on thread.main {
  let app = Application();
  app.services.register("notes", createNotesService());
  app.services.register("health", createHealthService());
  const createdWindow = attempt app.windows.create(WindowOptions({
    title: "Z Notes",
    url: "/notes",
    inject: Array<String>("base"),
    width: 720,
    height: 460,
  }));
  match (createdWindow) {
    success(_) => {}
    failure(_) => return 71;
  }
  return match (attempt await app.run()) {
    success(status) => status;
    failure(_) => 70;
  };
}
```

`WindowOptions` is an ordinary value struct with defaults. `create` returns a
shared `Window` identity or a typed `WindowError`, and the manager retains every
open window. The primary WebView calls the focused frontend `createWindow()`
factory after `app.run()` has entered the AppKit loop, dynamically realizing a
second window with its own native ID, request registry, and URL. The request is
handled by the framework before application service dispatch and reaches the
same application-owned `WindowManager`. `Window.show()`, `hide()`,
`setTitle()`, and idempotent `close()` are main-executor operations. The process
stops only after the last native window closes.

The frontend window factory is allowed explicitly by
`security.permissions: ["window:create"]`. Zapp mirrors that manifest for a
friendly TypeScript error, but the compiled Z router remains authoritative: a
handcrafted `__window:create` message cannot bypass the permission check.
The config also declares a `default` capability profile granting the `notes`
and `health` services plus window creation, and a narrower `diagnostics`
profile granting only `notes.count` and `health.status`. The primary window
uses `default` through `WindowOptions`' default value. Its frontend-created
child inherits that exact profile; Web content cannot submit a different
capability list. The smoke's successful calls from both windows therefore
exercise native profile enforcement and inheritance, while focused framework
tests prove a narrow profile returns a structured `PermissionDeniedError`
before service code runs.

`WindowOptions.url` is a logical application-relative URL, not a transport
address. This example deliberately uses `/notes`. In a packaged build the
macOS backend resolves it against `zapp://app/` and serves the embedded
`index.html` fallback plus its external `/app.js` module. In development the
same value resolves against the configured Vite/Bun HTTP origin. Application
source does not branch on build mode and cannot use this field to grant the
native bridge to an arbitrary remote origin.

The primary window selects the `base` profile declared by
`zapp.config.ts` through `inject: Array<String>("base")`. Its CSS,
document-start TypeScript, and document-end TypeScript are compiled into an
immutable native catalog. The smoke proves the bridge precedes the preload,
the style reaches the document, and the end script runs. The dynamically
created diagnostics window receives neither application-authored profile. The
`diagnostics` profile still exists in the compiled catalog, so the smoke proves
Web content cannot select or inherit trusted injection merely by creating a
window.

Application code now imports only Zapp's public source facade under
`native/z/api/`; it no longer reaches into framework implementation modules.
The source-local `z.json` declares one local `zapp` package dependency; Zapp's
library manifest exposes `"zapp"`, `"zapp/window"`, and `"zapp/service"` for
direct checking and editor services. That same manifest owns Zapp's framework
header paths and AppKit/WebKit/CoreFoundation link requirements through
`library.native`; this application does not repeat them. The build generates
an equivalent local dependency after staging the app, API, and framework into
one isolated workspace, so it does not rewrite authored imports. A future registry
dependency can replace the local path without changing application source or
Zapp's declared public exports.

This spike now builds and runs through Z's fixed-point native driver. Manual
`TaskScope` construction, owned capture transfer, main-executor placement, and
scope close/join all execute without a Stage 0 override.

`NotesCore` is a normal readonly ARC class with synchronized state and owns the
single implementation of `create`, `count`, JSON decoding, and JSON encoding.
`NotesService` is the application-owned service. Its public `create` and
`count` methods are the frontend API. `count` is a real main-executor `async`
method, while `create` is synchronous Z and throws an exported
`NoteCreationError` for an empty title. Generated dispatch preserves that
declared Z error as a typed WebView failure with decoded `details`; it remains
separate from cancellation's `AbortError`. Generated TypeScript bindings expose
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
├── bridge.zs
├── bridge/
└── platform/
```

The application-facing declarations live separately in `native/z/api/` so
framework implementation files cannot accidentally become package API.

This layer owns application lifecycle, frozen service routing, bridge envelope
decoding, typed outcomes, AppKit/WebKit identity, and deterministic shutdown. It
has no dependency on `NotesService` or any other application type.

## Run it

From the repository root:

```sh
bun run spike:z-notes
```

The visible macOS app dynamically opens a second diagnostics window and stays
open until both windows are closed. Click **Create a note in Z** to call the
generated `notes.create` TypeScript binding. Each path first verifies the
generated `NoteCreationError` and its structured details, then displays the
returned native-service value in the DOM. **Cancel a suspended request**
starts `notes.count`, aborts it with a standard `AbortController` while the
service is yielded, and then proves a later request still succeeds. Expected
evidence after creating a note directly:

```text
Notes: notes service started
visible WebView round trip window=1 request=3 ok=true hmr=packaged inject=ready payload={"id":"1","title":"WebView note"}
visible WebView round trip window=2 request=2 ok=true hmr=packaged inject=ready payload={"id":"2","title":"WebView note"}
Notes: notes service stopped
```

`zapp/z.json` combines the application-owned macOS 14 deployment target with
the package-owned AppKit, WebKit, CoreFoundation, and project-header context
used by the staged Zapp build. The Zapp CLI still owns final host-library
generation and linkage.

For a bounded automated round trip that aborts request 1, proves any raced
native response cannot publish stale state, completes request 2, and then
closes on success:

```sh
bun run spike:z-notes:smoke
```

That smoke runs a real Vite production build and then exercises its
Brotli-compressed output embedded directly in the native binary. For the
interactive development loop with Vite HMR:

```sh
bun run spike:z-notes:dev
```

The same logical `/notes` URL resolves against the live Vite origin without
changing Z source. Closing the native application is authoritative: the CLI
terminates the complete Vite process tree, waits for it to exit, and releases
the development port before the command completes. The bounded form proves the
same behavior automatically:

```sh
bun run spike:z-notes:dev-smoke
```

The desktop smoke reports `hmr=ready` in development and `hmr=packaged` in a
production build, so a stale packaged frontend cannot masquerade as a working
development session.

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
