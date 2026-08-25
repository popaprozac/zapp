# Z Notes application spike

This is the first Zapp project whose application-owned Z source is physically
separate from the reusable framework. It is intentionally still a spike: the
runtime behavior is real, while package-resolved `zapp` imports remain
productization work.

## The end-user application

An application author currently owns four files under `zapp/`:

```text
zapp/
├── z.json            # editor/native header and deployment context
├── main.zs           # desktop entry and Application configuration
├── embedded.zs       # strict-C embedding entry used by the regression host
└── notes-service.zs  # service model, behavior, and checked handler conversion
```

The ordinary desktop entry is deliberately small:

```z
import { createNotesService } from "./notes-service.zs";
import { Application } from "../../../native/z/framework/application.zs";

function main(): i32 {
  let app = Application({ name: "Notes" });
  app.services.registerWithLifecycle("notes", createNotesService());
  return match (attempt app.run()) {
    success(status) => status;
    failure(_) => 70;
  };
}
```

The repository-relative framework import is temporary. A real package/module
resolver should make it an ordinary stable Zapp import without copying runtime
sources into an application. The build stages the app and framework into one
isolated workspace today so the fixed-point compiler and editor inspect the
same source graph.

`NotesService` is a normal readonly ARC class with synchronized state. Its
public `create` and `count` methods are the frontend API. It implements
`Service` with a framework-synthesized callable around `invoke()` and
`ServiceLifecycle` with main-thread `start` and `stop` methods.
`registerWithLifecycle` derives both
adapters from the same service identity; the application does not register the
service twice. Framework methods are excluded from generated TypeScript
bindings. The framework owns the registered service name and method-prefix
routing; the service does not repeat a route list, capture its registration
name, or construct a binding object.

## The reusable framework

The code an application should not own now lives under:

```text
native/z/framework/
├── application.zs
├── application-contract.zs
├── services.zs
├── service-contract.zs
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
the returned native-service value in the DOM. Expected evidence after a click:

```text
Notes: notes service started
visible WebView round trip window=1 request=1 ok=true payload={"id":"1","title":"WebView note"}
Notes: notes service stopped
```

`zapp/z.json` gives direct editor analysis and `z check` the same macOS 14,
AppKit, WebKit, CoreFoundation, and project-header context used by the staged
Zapp build. The Zapp CLI still owns final host-library generation and linkage.

For a bounded automated round trip that clicks and closes on success:

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
