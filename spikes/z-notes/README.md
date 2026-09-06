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
├── notes-persistence.zs # application-owned SQLite storage
├── notes-transfer.zs # versioned JSON import/export codec
├── notes-transfer.test.zs # native codec round-trip regression
├── sqlite3.h.zd      # checked SQLite ownership/status/text contract
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
  const app = new Application();
  const notesRegistered = attempt app.services.register(
    "notes",
    createNotesService()
  );
  match (notesRegistered) {
    success => {}
    failure(_) => return 78;
  }
  const healthRegistered = attempt app.services.register(
    "health",
    createHealthService()
  );
  match (healthRegistered) {
    success => {}
    failure(_) => return 79;
  }
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

The notes lifecycle hook also retrieves `Application.current()` during startup
and verifies that it is the same configured application now in the `running`
state. It creates `context.paths.data`, opens one application-owned SQLite
database at `notes.sqlite3`, restores prior notes and their next ID, and seeds a
welcome note only when the database is empty. The service retains the native
handle for its full lifecycle and releases it deterministically during stop.
This demonstrates that ordinary application code neither hardcodes macOS
directories nor repeatedly opens native storage for each request. The app's
`z.json` declares `sqlite3` because it is a native dependency of Z source,
while `zapp.config.ts` remains concerned with framework/product configuration.
The embedded frontend calls the generated `notes.list()` binding on launch,
renders those persisted values, and refreshes the same list after typed
`notes.create(...)`, `notes.edit(...)`, `notes.archive(...)`, and
`notes.delete(...)` calls. Each existing note exposes Save, Archive, and Delete
controls. Mutations persist to SQLite before the application-owned catalog is
changed, return the resulting `Note`, and surface a generated
`NoteMutationError` with the affected note ID and message. A title field and
Enter-key submission keep this a small usable notes surface while the worker,
cancellation, and native-window controls remain visible as composition
diagnostics.

**Import JSON…** and **Export JSON…** exercise the application-owned
`app.dialogs` and `app.files` managers through generated async service bindings.
The dialog grants the selected path, then the files manager performs UTF-8 I/O
on a native worker while the main-executor service task is suspended. Cancellation
is ordinary absence (`null` in generated TypeScript, `Option.none` in Z), while
native dialog, filesystem, and codec failures become a generated
`NoteTransferError`. Export writes a versioned document containing portable
note content rather than database IDs. Import validates that document, assigns
fresh IDs, persists the complete batch in one SQLite transaction, and only
then publishes the notes to the main-thread catalog; a failed batch leaves both
the database and in-memory model unchanged. The WebView never receives or
submits an arbitrary filesystem path.

After the platform loop exits, the smoke checks that the retained `app`
identity has transitioned to `stopped`.

The public application identity also owns cancellable shutdown observation:

```z
const subscription = try app.events.quitRequested.subscribe(
  move (in event: ApplicationQuitRequestedEvent): void => {
    if (hasUnsavedWork()) event.cancel();
  }
);

app.quit();
const status = try await app.run();
```

On macOS the same event is consulted for programmatic quit, Cmd-Q, Dock Quit,
and system termination. Cancellation affects only that request; accepted
shutdown resolves `run()` after windows, workers, and services have completed
their normal teardown.

Z Notes installs an application menu from both sides of Zapp's command model.
Before `run()`, native Z supplies the initial standard roles plus a
project-owned **Notes → Log Note Count** command that calls the registered Z
service directly on `thread.main`. Once the primary WebView is ready, its
focused `Application.current().menu` facade intentionally replaces that menu
with standard App/File/Edit/Window groups and an async **File → New Note**
command. The frontend command calls the generated `notes.create(...)` service,
refreshes the same UI, and remains owned only by that WebView generation. The
same File menu includes a checked **Auto-name Empty Notes** command. Its action
receives a `CommandInvocation`, transactionally flips `CommandState` through
the native bridge, and AppKit updates every installed item sharing that command
identity before the frontend commits its local state.
Closing the owner or replacing its menu invalidates the opaque callback token.
The child diagnostics WebView cannot race to become the application-menu
owner. Native Z commands never cross IPC; frontend commands cross only for
their eventual callback delivery.

`WindowOptions` is an ordinary value struct with defaults. `create` returns a
shared `Window` identity or a typed `WindowError`, and the manager retains every
open window. The primary WebView calls the focused frontend `createWindow()`
factory after `app.run()` has entered the AppKit loop, dynamically realizing a
second window with its own native ID, request registry, and URL. The request is
handled by the framework before application service dispatch and reaches the
same application-owned `WindowManager`. `Window.show()`, `hide()`,
`setTitle()`, and idempotent `close()` are main-executor operations. The process
stops only after the last native window closes.

Frontend code imports these capabilities from `@zappdev/runtime/window`. That
focused boundary exposes the composed factories, handle operations, and
focus/blur/resize subscriptions without carrying forward the legacy `Window`
namespace or loading its broad implementation. New capabilities join it only
after their Z-owned native route and frontend contract work together end to
end. Resize delivers the same
`{ windowId, size }` value as Z's `WindowResizedEvent`; it does not manufacture
position or timestamp fields that the native event did not provide.

The frontend window factory is allowed explicitly by
`security.permissions`, alongside `menu`, `clipboard:read`, and
`clipboard:write`. Zapp mirrors that manifest for a
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

The config also compiles a `default` navigation profile. It permits the
logical application origin and `https://docs.z-language.com`; the primary
window uses that profile through `WindowOptions.navigation`'s default. The UI
contains two visible subframe probes: one origin is rejected by the compiled
profile, while a profile-approved documentation URL is cancelled by a trusted
Z `window.events.navigationRequested` subscriber. The TypeScript
`WindowEvent.NAVIGATION_REQUESTED` subscription observes both final decisions
but cannot change either one. The frontend-created diagnostics window inherits
the same profile. **Open Z documentation** first proves a `file:` URL is
rejected with a focused `ShellError`, then deliberately opens an allowed
`https:` URL through `Application.current().shell.openExternal(...)`.
The route intersects the app-wide permission, the window capability profile,
and its compiled navigation scheme list; navigation itself never performs an
automatic shell handoff.
**Reveal app resources** first proves `$home` is rejected, then reveals the
allowlisted `$resources` directory. This second route intersects
`shell:reveal` at application and window scope with the compiled filesystem
path authority; it does not require a redundant filesystem read permission.
The third navigation-policy button loads a same-origin subframe that attempts
to send a raw WebKit close message without the Zapp bootstrap. Native routing
rejects it because only the main frame at `"self"` owns bridge authority.

The primary WebView also exercises the application-owned clipboard from the
focused TypeScript facade. **Copy note title** writes the current title,
**Read text** distinguishes `null` from an empty string, and **Clear** replaces
the pasteboard contents. The same `Application.current().clipboard` surface is
backed by direct `NSPasteboard` calls in Z; there is no handwritten clipboard
shim. Both application policy and the originating window's `default`
capability profile explicitly grant the operation.

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

Z Notes declares a ZJS application worker through the same `zapp.config.ts`
surface an application will use. The CLI bundles and embeds its source module,
native Z starts it after the Notes services, and application shutdown requests
cancellation and joins the worker before those services stop. The UI's
**Index notes in a Zapp worker** action asks that application-lifetime worker to
load an owned `Array<Note>` through the generated service API, analyze the
actual titles off the WebView thread, and publish progress plus a summary. The
same output is independently observable through native Z's `worker.messages`
and the authorized WebView subscription. A welcome note seeded by native Z on
the first launch makes the automated path exercise a real `Note` value rather
than an empty collection. Notes created from either WebView are stored before
publication, appear in later manual indexes, and reload on the next packaged
launch.

The indexer also exercises Z-authored worker protocols rather than duplicating
payload interfaces by hand. `zapp/note-indexer-protocol.zs` declares exported
command/message enums and aliases
`WorkerProtocol<NoteIndexerCommand, NoteIndexerMessage>`. The config names that
checked alias, and the build generates `zapp:workers` for both environments:

```ts
// WebView
import { noteIndexer } from "zapp:workers";

await noteIndexer.commands.indexNotes({ requestId: "manual-1" });
const subscription = noteIndexer.messages.subscribe((message) => {
  switch (message.kind) {
    case "started":
    case "progress":
    case "complete":
    case "failed":
      console.log(message.value);
      break;
  }
});
```

```ts
// ZJS application worker
import { defineNoteIndexerWorker } from "zapp:workers";

const dispatch = defineNoteIndexerWorker({
  indexNotes(input, messages) {
    messages.started({ requestId: input.requestId });
    // Analyze notes through the same generated `zapp:services` API.
  },
});
```

The Z marker disappears at build time. Variant names use the existing worker
channels directly, while generated codecs validate every payload and preserve
the `u64` note identity exactly.

The opt-in worker smoke proves that workflow without manual UI interaction:

```sh
bun run spike:z-notes:worker-smoke
```

The persistence smoke builds once under a dedicated test-only application
identifier, removes only that isolated data directory, and launches the same
binary twice. The first launch seeds ID 1 and stores WebView notes 2-3; the
second must reload all three before creating IDs 4-5:

```sh
bun run spike:z-notes:persistence-smoke
```

A second smoke selects an intentionally failing build-only worker and proves
the existing restart contract end to end. With `maxRetries: 2`, native ZJS
creates exactly three engine incarnations, then gives up while the application
and its services still shut down normally:

```sh
bun run spike:z-notes:worker-restart-smoke
```

This configured tier proves module load, deterministic lifetime, a bounded
private host-to-worker command path, and the first direct worker-to-Z service
route. Worker code imports the same generated facade used by the WebView:

```ts
import { health } from "zapp:services";

const status = await health.status();
```

The public method, Promise result, generated codecs, and runtime error classes
do not expose the transport choice. In this ZJS application worker,
`health.status()` calls the frozen synchronous Z service router in process;
`notes.isEmpty()` suspends on Z's main executor and resumes the same generated
Promise on the worker thread; the equivalent WebView calls use request/response
IPC. The worker's immutable
`diagnostics` capability profile is authoritative on the direct path too: the
smoke calls ungranted `notes.create()` and requires the ordinary generated
Promise to reject with `PermissionDeniedError` before Notes service code runs.

The smoke queues `ping` immediately—even before the module may have
initialized—and fails unless the worker dispatches it, calls synchronous and
suspending authorized services, cancels a second suspended request, observes
the typed denial, and replies on `pong`. Cancellation forwards to the native Z
task rather than merely dropping the JavaScript result. The focused
`@zappdev/runtime/worker` facade also exposes authorized frontend-to-worker
`send` and worker-to-frontend `subscribe` without exposing the legacy runtime.

Native Z code uses the application-owned `app.workers` manager. Configured
handles exist before `app.run()`, so subscriptions can observe startup; engine
dispatch becomes available during the run and fails with a typed error outside
that lifetime. The protocol marker selects the configured worker and gives Z a
typed command/message facade without repeating its id or wire channels:

```zs
import {
  ApplicationWorkerEvent,
  ApplicationWorkerProtocolError,
} from "zapp/worker";
import {
  IndexNotes,
  NoteIndexerCommand,
  NoteIndexerMessage,
  NoteIndexerProtocol,
} from "./note-indexer-protocol.zs";

const selected = app.workers.get(NoteIndexerProtocol());
const worker = match (selected) {
  some(value) => value;
  none => return 1;
};
const { restarting: restarts } = worker.events;
const restartSubscription = try restarts.subscribe(
  move (in event): void => console.log(
    `retry ${event.retry}/${event.maxRetries}`
  )
);
const lifecycleSubscription = try worker.events.all.subscribe(
  move (in event: ApplicationWorkerEvent): void => match (in event) {
    started(value) => console.log(`started ${value.workerId}`);
    restarting(value) => console.log(`restarting ${value.workerId}`);
    failed(value) => console.log(`failed ${value.workerId}`);
    stopped(value) => console.log(`stopped ${value.workerId}`);
  }
);
const messageSubscription = try worker.messages.subscribe(
  move (
    in received: Result<NoteIndexerMessage, ApplicationWorkerProtocolError>
  ): void => match (in received) {
    success(message) => match (in message) {
      started(value) => console.log(`started ${value.requestId}`);
      progress(value) => console.log(
        `${value.completed}/${value.total}`
      );
      complete(value) => console.log(`indexed ${value.total}`);
      failed(value) => console.log(value.message);
    };
    failure(error) => console.log(
      `protocol error on ${error.channel}: ${error.message}`
    );
  }
);

const sent = attempt worker.send(
  NoteIndexerCommand.indexNotes(IndexNotes({ requestId: "native-smoke" }))
);
match (sent) {
  success => console.log("index requested");
  failure(error) => console.log(error.message);
}

// Explicit escape hatch for an undeclared diagnostic channel.
const raw = app.workers.getRaw("noteIndexer");
match (raw) {
  some(handle) => try handle.send("manager-ping", "smoke");
  none => {}
}

return try await app.run();
```

`worker.events` is an ordinary readonly Z value, so applications can use
destructuring and local aliases such as
`const { restarting: restarts } = worker.events;`. Lifecycle handlers run on
`thread.main`; focused events avoid unnecessary matching, while `events.all`
supports one exhaustive observer. Subscriptions own their registration and
automatically unsubscribe at lexical cleanup, or may call `unsubscribe()`
early. Typed `worker.send(command)` is available while `app.run()` owns the
active engine controls; Z Notes exercises it from the `started` lifecycle arm.
Typed `worker.messages` carries decoded application data rather than lifecycle
state and reports invalid payloads as values. The separate raw handle retains
immutable `workerId`, `channel`, and `payload` transport for deliberate escape
hatches. Z Notes proves that typed and raw native subscribers plus authorized
WebViews can independently observe the same worker output.

The current compatibility ZJS artifact also
receives an unminified worker module because it misexecutes one Rolldown
compact-control-flow rewrite. Other engines retain minification, and the ZJS
rewrite must close this compatibility test before reclaiming it.

The same configured worker has a repeatable fast-path benchmark:

```sh
bun run bench:z-notes:worker
```

The post-continuation September 2, 2026 Apple M4 Pro checkpoint measures
399 ns/call at the direct host boundary and 2.253 us/call through the generated
Promise API. See
[the worker service benchmark](../../benchmarks/z-worker-services.md) for the
exact boundary, sample ranges, and remaining allocation/copy analysis.

`NotesCore` is a normal readonly ARC class with synchronized state and owns the
single implementation of `create`, `count`, JSON decoding, and JSON encoding.
`NotesService` is the application-owned service. Its public `create` and
`count` methods are the frontend API. `create` is a suspending main-executor
method and throws an exported `NoteCreationError` for an empty title. `count`
is synchronous and main-isolated; generated dispatch taskifies that placement
without changing the authored API. Generated dispatch preserves that
declared Z error as a typed WebView failure with decoded `details`; it remains
separate from cancellation's `AbortError`. Generated TypeScript bindings expose
both service invocations uniformly as cancellable promises.
`CreateNoteInput.subtitle?: String` proves an omitted Web input becomes Z
`Option.none`; the returned `Note` exposes that absence as JSON `null` and a
generated `string | null` TypeScript field. `NoteState` proves an exported
payload-free Z enum becomes a checked string union with generated runtime
values and exhaustive native codecs; `isArchived(state: NoteState)` also sends
that enum directly from the WebView into a Z method. `NoteDescription` proves
payload enums use the uniform `{ kind, value }` tagged shape and round-trip an
owned `String` payload through generated JavaScript, TypeScript, and native Z
codecs. The build now
generates and installs its checked `AsyncService` dispatcher plus lifecycle
forwarder into the isolated staged application. The original `main.zs` remains
unchanged. One `register` call derives the async dispatcher and lifecycle
forwarder from the same service identity; the application does not register the
service twice. `NotesService` has no author-facing `invoke()` or `AsyncService`
conformance. Framework methods are excluded from generated TypeScript
bindings. The framework owns the registered service name and method-prefix
routing; the service does not repeat a route list, capture its registration
name, or construct a binding object. The explicit `"notes"` registration name
is also the stable frontend, wire-routing, diagnostic, and capability identity:
grants such as `"notes.create"` visibly authorize the same service installed by
application source rather than a name inferred from its implementation class.

`HealthService` is a sync-only value struct registered through the same API.
Its generated adapter implements the non-task `Service` path, and the WebView
smoke calls `health.status()` after the async Notes flow. This proves automatic
adapter selection without charging synchronous services task overhead.

The strict-C embedding entry uses `SyncNotesService`, a thin synchronous
adapter around the same `NotesCore`. This keeps that host from importing task
runtime code merely to exercise direct native invocation. It is a transport
boundary, not a second implementation of the Notes domain.

The cancellable `count` request crosses the generated task wrapper and explicit
main-executor placement even though the authored method is synchronous. The
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

The runner places the executable inside a minimal ad-hoc-signed development
`.app` before launching it. That bundle identity is required by native services
such as `UNUserNotificationCenter`; invoking the same binary directly from the
build directory is not an equivalent application environment.

The visible macOS app dynamically opens a second diagnostics window and stays
open until both windows are closed. Click **Create a note in Z** to call the
generated `notes.create` TypeScript binding. Each path first verifies the
generated `NoteCreationError` and its structured details, then displays the
returned native-service value in the DOM. Edit a rendered title and click
**Save**, **Archive**, or **Delete** to exercise the generated mutation
bindings, typed `NoteMutationError`, application-owned catalog, and persistent
SQLite connection without handwritten frontend routing. Use **Export JSON…**
and **Import JSON…** to verify native save/open panels, typed cancellation, and
the versioned Z-owned transfer codec. **Cancel a suspended request**
starts `notes.count`, aborts it with a standard `AbortController` while the
service is yielded, and then proves a later request still succeeds. Expected
evidence after creating a note directly:

```text
Notes: notes service started
visible WebView round trip window=1 request=6 ok=true hmr=packaged inject=ready payload={"id":"1","title":"WebView note","subtitle":null,"state":"active"}
visible WebView round trip window=2 request=4 ok=true hmr=packaged inject=ready payload={"id":"2","title":"WebView note","subtitle":null,"state":"active"}
Notes: notes service stopped
```

`zapp/z.json` combines the application-owned macOS 14 deployment target with
the package-owned AppKit, WebKit, CoreFoundation, and project-header context
used by the staged Zapp build. The Zapp CLI still owns final host-library
generation and linkage.

For a bounded automated round trip that aborts request 1, proves any raced
native response cannot publish stale state, completes request 2, checks the
non-prompting notification-permission status path in both windows, and then
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
