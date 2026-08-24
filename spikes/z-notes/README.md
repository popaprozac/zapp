# Z Notes application spike

This is the first Zapp project whose application-owned Z source is physically
separate from the reusable framework. It is intentionally still a spike: the
runtime behavior is real, while package-resolved `zapp` imports remain
productization work.

## The end-user application

An application author currently owns three files under `zapp/`:

```text
zapp/
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
  app.services.register("notes", createNotesService());
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

`NotesService` is a normal readonly Z value with synchronized state. Its public
`create` and `count` methods are the frontend API. It implements the framework's
`Service` trait through a consuming `handler()` conversion. That method is
excluded from generated TypeScript bindings. The framework owns the registered
service name and method-prefix routing; the service does not repeat a route
list, capture its registration name, or construct a binding object.

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

The visible macOS app calls the generated `notes.create` TypeScript binding,
verifies the DOM update, and closes automatically. Expected evidence:

```text
visible WebView round trip window=1 request=1 ok=true payload={"id":"1","title":"WebView note"}
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
