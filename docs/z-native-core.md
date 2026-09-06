# Z native core

Status: Phase 0 complete; Phase 1 typed ingress, dynamically created Z-owned
AppKit/WebKit windows, generated typed service round trips, structured
suspending service delivery through real WebViews, and the first direct ZJS
worker-to-Z service route complete, August 2026.

Zapp's reusable native core lives under `native/z/framework/`; the first
application-owned source graph lives under `spikes/z-notes/zapp/`. It is a
from-scratch Z implementation, not a translation of the current Nim or Zen-C trees. Those
implementations remain the behavioral and performance oracle until the Z core
reaches equivalent application behavior and measurement coverage.

## What works now

`ZAPP_NATIVE_LANG=z` routes the ordinary CLI native compilation seam through
the Z builder. The builder:

1. resolves `ZAPP_Z_COMPILER`, the sibling fixed-point compiler, or `z` from
   `PATH`;
2. runs `z version` and validates the exact language, compiler revision, and
   compiler API in `native/z/compiler-contract.json`;
3. stages the reusable framework and project-owned `zapp/` sources in an
   isolated workspace under the application's gitignored
   `.zapp/z-native-core/` directory;
4. builds `libzapp_core.a` with the Z compiler;
5. links the generated native adapter archive and compiler-embedded Z asset
   catalog into the CLI output;
6. initializes a process-wide Z `Application` through the generated runtime
   initializer, routes owned UTF-8 messages through Z, and shuts the root down
   deterministically;
7. consumes the checked `z metadata` graph already validated from the persistent
   frontend cache or produced by the current frontend preflight when every
   module, package manifest, compiler contract, and compiler identity is still
   current; otherwise it refreshes the graph from the isolated workspace, then
   generates transport-independent typed TypeScript service bindings;
8. links either the default AppKit/WebKit application host or the focused
   strict-C bridge host used by the non-UI regression; and
9. bundles the canonical `bootstrap/webview.ts` source and generated browser
   service facade, then injects both through a `WKUserScript` at document start;
10. compiles the WebView origin, bootstrap, and `webview.inject` catalog into
    a generated typed Z module, then lets each `WindowOptions.inject` select
    its trusted profile set before navigation;
11. expands `security.capabilities` service selectors against the checked
    service manifest, compiles exact grants into immutable Z collections, and
    enforces the originating window's selected profiles before dispatch;
12. checks optional Z-authored `WorkerProtocol<Command, Message>` aliases,
    generates transport-neutral TypeScript command/message codecs, bundles
    configured application workers, passes each worker only its expanded
    immutable service-method allowlist, routes synchronous `thread.any` calls
    directly into the frozen Z router, and retains suspended service
    continuations until their owning worker can settle them; and
13. creates the native Z `app.workers` manager before `run()`, installs its
    engine-neutral dispatch operation during application startup, publishes
    typed lifecycle and application-message events on `thread.main`, preserves
    independent authorized WebView forwarding, and closes dispatch and event
    sources before worker controls are destroyed during shutdown.

## One service API, environment-selected transport

Generated frontend and worker code imports one facade:

```ts
import { health } from "zapp:services";

const status = await health.status();
```

The generated method always returns the same cancellable Promise shape and
uses the same argument/result codecs and runtime error classes. A WebView sends
the call through the asynchronous bridge protocol. A configured ZJS
application worker instead enters an internal engine host function. A
synchronous service calls Z's frozen `Services` router in process and resolves
the public Promise immediately. A suspending service returns a native Promise,
records its Z `TaskControl`, runs on the declared executor, and queues
completion back to the worker-owned engine thread. No renderer or WebView IPC
participates in either path.

Transport selection is internal; it is not an application choice and does not
create a second worker-specific service namespace. Native Z checks the
worker's build-expanded service-method allowlist before dispatch, so bypassing
the JavaScript facade cannot broaden authority. Structured denials and typed Z
service failures return through the same runtime error normalization as WebView
responses.

Cancellation uses the same generated `CancellablePromise` surface in every
environment. A pre-aborted signal prevents native entry. Cancelling a suspended
worker request rejects locally with `AbortError`, forwards the request identity
to native Z, and asks the recorded `TaskControl` to cancel. Completion and
cancellation races are idempotent: the first terminal outcome releases the
worker continuation, and a late native completion is ignored. The current ZJS
adapter bounds each worker to 64 simultaneously suspended service calls; excess
calls fail rather than allocating an unbounded native continuation table.

## Checked worker protocols

Application workers may additionally name a checked Z protocol in
`zapp.config.ts`. The protocol is an exported alias of
`WorkerProtocol<Command, Message>`, where both roots are exported Z enums and
their payloads use the same supported wire-value graph as services. The marker
is compile-time evidence only. Its enum variants map directly onto the existing
worker channel names, so typed commands do not add an envelope or another IPC
layer.

The generated `zapp:workers` module serves both environments. WebViews receive
`worker.commands.<variant>(payload)` and a discriminated
`worker.messages.subscribe(...)` stream. Worker modules receive a generated
`define<Worker>Worker(...)` dispatcher and a message publisher whose methods
are limited to declared variants. Raw `send` and `subscribe` remain available
as an explicit escape hatch and can coexist with the generated dispatcher.

Native Z uses that same checked evidence. `app.workers.get(ProtocolMarker())`
returns an `ApplicationWorker<Command, Message>` whose `send` accepts the
command enum and whose message subscription receives
`Result<Message, ApplicationWorkerProtocolError>`. The generated build overlay
binds the marker to the configured worker identity and inserts the codecs; the
authored application does not repeat an id, channel, or JSON shape. Explicit
`getRaw(id)` remains available for diagnostic and migration channels.

Worker bundling removes the unused WebView client half of the generated module.
Collection codecs use explicit checked loops rather than depending on optional
or engine-specific `Array.map` behavior, while exact `u64`/`i64` values retain
their decimal-string wire representation.

Configured ZJS restart policy is executable in this replacement path too. An
uncaught module, message, continuation, or event-loop failure destroys the
failed engine context, cancels any service tasks whose JavaScript continuations
were owned by it, and creates a fresh context from the same immutable embedded
module. `maxRetries` bounds replacement incarnations inside `withinMs`; the
next failure gives up instead of looping forever. Messages already accepted
into the native inbox remain queued across an engine replacement. Public
restart/crash lifecycle events are a later manager slice; the current runtime
reports each incarnation and terminal give-up through application diagnostics.

The post-continuation checkpoint records a 399 ns median for the direct ZJS
host boundary and 2.253 us through the actual generated Promise API on an Apple
M4 Pro. The latter is approximately 35 times faster than the established 79 us
WebView no-op checkpoint. Methodology, sample ranges, boundary differences, and
remaining ownership copies are recorded in
[Z worker service benchmark](../benchmarks/z-worker-services.md).

The route is no longer a pass-through smoke. Z's source-backed `std/json`
parser decodes the WebView envelope into `BridgeMessage`, preserves request
identities through the full `u64` range, and distinguishes framework responses,
handled fire-and-forget operations, and messages available to another router.
This prevents a recognized action from accidentally falling through as a
service invocation. Arbitrary `a` payloads are serialized at the ingress edge
and do not become the core's internal object model.

The default executable is now a visible multi-window AppKit/WebKit application.
Z creates and owns each window, WebView, configuration, content controller,
protocol handler, and registration guard. A per-window native registry retains
the run-loop-facing graph and routes each WebKit response by a stable native
identifier; Z owns each window's pending-request namespace and public identity.
The primary WebView invokes the focused frontend `createWindow()` factory after
the application loop starts, proving dynamic realization rather than
startup-only enumeration. The framework handles the built-in operation before
application service dispatch and calls the same Z-owned `WindowManager`. The
child inherits its creator's capability profiles; Web content cannot submit a
different profile list. Native-authored windows may select named profiles in
`WindowOptions`, while unknown names fail window realization with a typed
`WindowError`.

The focused frontend `WindowHandle` operations `show`, `hide`, `setTitle`, and
`close` now traverse that same production bridge and call the Z-owned
`WindowManager` on `thread.main`. They are intentionally fire-and-forget, so a
recognized action is consumed without manufacturing an invoke response;
malformed payloads and unknown window identities fail closed as no-ops. The Z
Notes smoke changes the native title after a typed service round trip, proving
WebView -> Z -> AppKit composition rather than only the manager seam.
The interactive page also exposes visible rename, temporary hide/show, and
close controls so the same production route can be exercised by hand.

The application identity now also owns a typed `DialogManager`. File and
directory selection are authority-granting application operations, so they are
not hidden behind a process-global `Dialog` namespace and WebView content does
not supply an arbitrary filesystem path:

```zs
import { FileFilter, OpenDialogOptions } from "zapp/dialog";

const selected = try await app.dialogs.openFile(OpenDialogOptions({
  title: "Import notes",
  filters: Array<FileFilter>(FileFilter({
    name: "JSON",
    extensions: Array<String>("json"),
  })),
}));

match (selected) {
  some(path) => importNotes(move path);
  none => {}
}
```

`openFile`, `openFiles`, `openDirectory`, and `saveFile` all return `Option`
for ordinary user cancellation and throw `DialogError` for native or framework
failure. Their public surface is async and `on thread.main`. The first macOS
backend uses AppKit's nested modal run loop internally; replacing it with
sheet-based suspension is an implementation improvement that does not change
application source. The headless backend fails with a typed unsupported error.
File filters use `UTType` directly, and no JSON serialization or legacy dialog
shim exists between Z and AppKit.

The application also owns a focused `ClipboardManager`. Text is the first
portable tier: reads distinguish an empty clipboard from an empty string,
writes replace the current contents, and clear uses the platform clipboard's
native invalidation operation.

```zs
import { Application } from "zapp";

const app = Application.current();
const text: Option<String> = try app.clipboard.readText();
try app.clipboard.writeText("Copied from Z");
try app.clipboard.clear();
```

These synchronous Z methods are `on thread.main` because the initial macOS
backend calls `NSPasteboard` directly. The focused WebView facade preserves the
same application-owned shape while naturally returning promises across IPC:

```ts
import { Application } from "@zappdev/runtime/application";
import { ClipboardError } from "@zappdev/runtime/clipboard";

const clipboard = Application.current().clipboard;
await clipboard.writeText("Copied from the WebView");
const text = await clipboard.readText(); // string | null
await clipboard.clear();
```

Clipboard reads and writes require separate `clipboard:read` and
`clipboard:write` grants. The originating window's capability profile narrows
the application-wide ceiling, and the Z router checks both before touching
AppKit. Trusted native Z application code calls the manager directly; the
permission boundary protects less-trusted WebView content. HTML, files, and
images remain future typed clipboard tiers rather than untyped payloads on the
text API.

System notifications follow the same application-owned manager shape, but are
async because operating-system authorization and delivery complete later. The
first portable tier reads or requests permission and delivers one text
notification. A denied request is an ordinary `NotificationPermission` value;
native failures throw `NotificationError`.

```zs
import { Application } from "zapp";
import {
  NotificationOptions,
  NotificationPermission,
} from "zapp/notifications";

const notifications = Application.current().notifications;
let permission = try await notifications.permissionStatus();
if (permission == NotificationPermission.notDetermined) {
  permission = try await notifications.requestPermission();
}
if (permission == NotificationPermission.granted) {
  const id = try await notifications.show(NotificationOptions({
    title: "Z Notes",
    body: Option.some("Your note was saved."),
  }));
}
```

The WebView facade has the same shape and uses promises across the bridge:

```ts
import { Application } from "@zappdev/runtime/application";
import {
  NotificationError,
  NotificationPermission,
} from "@zappdev/runtime/notifications";

const notifications = Application.current().notifications;
const permission = await notifications.requestPermission();
if (permission === NotificationPermission.Granted) {
  const id = await notifications.show({
    title: "Z Notes",
    body: "Your note was saved.",
  });
}
```

WebView calls require the app-wide `notifications` permission and the
originating window's capability profile must also grant it. Trusted native Z
code calls `app.notifications` directly. The macOS backend talks to
`UNUserNotificationCenter` through checked async `.zd` completion contracts;
there is no blocking semaphore, global response buffer, JSON hop, or handwritten
Objective-C adapter between the manager and the framework call. Scheduling,
actions, categories, and delivery events remain later typed tiers.

Operating-system handoff is a separate focused manager. URL handoff is
intentionally not a navigation side effect, and filesystem handoff remains
inside configured or user-approved path authority.

Trusted native dialogs add authority without exposing a separate grant API:

```zs
const selected = try await Application.current().dialogs.openFile(
  OpenDialogOptions({ title: "Choose a report" })
);
match (selected) {
  some(path) => try Application.current().shell.reveal(in path);
  none => {}
}
```

`openFile` and `saveFile` grant the exact selected path for the application
session. `openFiles` grants every returned path, while `openDirectory` grants
the directory and its descendants. All methods still return ordinary `String`
values inside `Option`; the nominal authorization evidence stays internal to
Zapp.

```zs
import { Application } from "zapp";
import console from "std/console";

const opened = attempt Application.current().shell.openExternal(
  "https://docs.z-language.com"
);
match (opened) {
  success => {}
  failure(error) => console.error(error.message);
}

try Application.current().shell.reveal("$resources");
```

The WebView facade preserves the manager shape:

```ts
import { Application } from "@zappdev/runtime/application";
import { ShellError } from "@zappdev/runtime/shell";

try {
  await Application.current().shell.openExternal(
    "https://docs.z-language.com",
  );
} catch (error) {
  if (error instanceof ShellError) {
    console.error(error.operation, error.target, error.message);
  }
}

await Application.current().shell.openPath("$userData/report.pdf");
await Application.current().shell.reveal("$userData/report.pdf");
await Application.current().shell.trash("$userData/old-report.pdf");
```

Frontend calls require the corresponding app-wide `shell:open`,
`shell:reveal`, or `shell:trash` grant and the same grant in the originating
window's capability profile. External URLs additionally require a matching
scheme in the selected navigation profile. Filesystem targets must resolve
inside `security.filesystem.allow` or authority established by a trusted file
dialog; `shell:*` authorizes the operation while the filesystem policy
constrains its target. Native Z does not serialize
through the WebView bridge or repeat its permission checks, but the focused
manager applies the same filesystem resource authority. Smoke mode exercises
the routes without launching another application, opening Finder, or moving a
file.

Text-file access is likewise focused rather than a duplicate filesystem
library:

```zs
const app = Application.current();
const source = try await app.files.readText(in path);
try await app.files.writeText(in path, in source);
```

`FileManager` composes Z's portable `std/fs` operations with Zapp's application
path authority and `FileError` context. Blocking reads and writes run on native
workers; awaiting them suspends the Z task instead of blocking `thread.main`.
WebView routes additionally require `fs:read` or `fs:write` in both the global
manifest and the originating window's selected capability profiles.

`Application` owns a single internal filesystem-authority identity shared with
its managers. The authority turns authored path aliases and absolute paths into
nominal `AuthorizedPath` evidence only after platform canonicalization and
compiled-root containment. The macOS backend currently supplies those low-level
mechanics through Foundation. As Z's portable filesystem standard library
matures, canonicalization, path operations, and other generally useful native
calls should move into `std/fs`; Zapp should retain only application policy,
configured roots, session grants, and focused framework errors.

The same application identity owns one logical application menu. Applications
define commands independently from native menu-item allocations, so the same
command identity can later power menus, shortcuts, and toolbars:

```zs
import {
  Command,
  CommandAction,
  CommandInvocation,
  CommandOptions,
  CommandState,
  Menu,
  MenuGroup,
  MenuItem,
  MenuRole,
} from "zapp/menu";

const saveAction: CommandAction = move (
  in invocation: CommandInvocation
): void => {
  saveDocument();
  invocation.command.setState(CommandState.on);
};
const save = new Command(
  CommandOptions({
    label: "Save",
    shortcut: "Primary+S",
    state: CommandState.off,
  }),
  saveAction
);

try app.menu.set(Menu({
  items: Array<MenuItem>(
    MenuItem.role(MenuRole.application),
    MenuItem.submenu(MenuGroup({
      label: "File",
      items: Array<MenuItem>(MenuItem.command(save)),
    })),
    MenuItem.role(MenuRole.edit),
    MenuItem.role(MenuRole.window)
  ),
}));
```

`MenuRole` requests typed platform behavior rather than embedding selectors or
string commands in application source. On macOS, Zapp expands conventional
application/edit/window groups and delegates responder actions such as copy,
paste, undo, and close to AppKit. Command actions receive a
`CommandInvocation`, including the durable command identity that fired.
`Command.setEnabled` and tri-state `Command.setState` update every installed
native item that shares the command. The backend owns its `NSMenu`,
`objc.Connection` target/action tokens, and state subscriptions until
replacement or application shutdown, where teardown clears the native menu and
releases the graph deterministically. No JSON or legacy Objective-C menu shim
sits between application Z and AppKit.

Trusted WebView code uses the same logical command model through focused
package exports:

```ts
import { Application } from "@zappdev/runtime/application";
import { Command, CommandState, MenuRole } from "@zappdev/runtime/menu";
import { notes } from "zapp:services";

const newNote = new Command({
  label: "New Note",
  shortcut: "Primary+N",
  action: async () => {
    await notes.create({ title: "Untitled" });
  },
});
const autoName = new Command({
  label: "Auto-name Empty Notes",
  state: CommandState.On,
  action: async ({ command }) => {
    await command.setState(
      command.state === CommandState.On
        ? CommandState.Off
        : CommandState.On,
    );
  },
});

await Application.current().menu.set([
  { role: MenuRole.Application },
  {
    label: "File",
    items: [
      { command: newNote },
      { command: autoName },
      { type: "separator" },
      { role: MenuRole.Close },
    ],
  },
]);
```

The native menu remains an ordinary AppKit menu. Invocation and transactional
state changes for a WebView-owned command cross the bridge. A rejected native
update leaves the local TypeScript command unchanged. Each installation receives an opaque
owner token and command identities; replacement or owner-window teardown
invalidates that generation before releasing its callbacks. A stale WebView
cannot mutate or receive callbacks from a newer application menu. The `menu`
application permission and originating window's capability profiles are both
checked by native Z before installation or mutation.

Each Z-owned `Window` also exposes a typed, main-executor event surface. Event
channels are ordinary Z objects rather than stringly framework callbacks:

```zs
import {
  WindowCloseRequestedEvent,
  WindowClosedEvent,
} from "zapp/window";

const closeRequested = try window.events.closeRequested.subscribe(
  move (in event: WindowCloseRequestedEvent): void => {
    if (hasUnsavedChanges()) event.cancel();
  }
);
const closed = try window.events.closed.subscribe(
  move (in event: WindowClosedEvent): void => {
    console.log(`window ${event.windowId} closed`);
  }
);

window.close();
```

The focused initial surface includes `focused`, `blurred`, `resized`, and
`closeRequested` and terminal `closed` channels plus `window.events.all`.
`window.close()` requests the operation; it does not claim that closing has
already completed. `closeRequested` is dispatched synchronously on the main
executor before AppKit or the inactive backend commits the close. Any handler
may call `event.cancel()`, and cancellation is monotonic for that request. If
the request proceeds, `closed` is published exactly once after the manager has
removed the native and Z-owned window state.

Multiple subscribers are allowed. A specific channel publishes before `all`,
and each channel preserves subscription order. `window.events.all` observes the
same `WindowCloseRequestedEvent`, so an aggregate handler may also cancel it.
`unsubscribe()` is explicit and idempotent; dropping the subscription also
unregisters it deterministically through `deinit`. Once `closed` publishes, all
channels reject later subscriptions and release their handler registries before
native shutdown. `WindowEventSubscription` remains useful when a subscription
must be stored or passed independently; local inference normally keeps the
common case concise.

The AppKit delegate callbacks enter Z through the native registration owner and
publish under a dedicated structured `TaskScope`. Shutdown closes and joins that
scope before releasing the Z-owned window graph, so native callbacks cannot race
framework teardown. The public event objects remain platform-neutral; future
backends provide their own native callback adapters.

AppKit focus, blur, and resize callbacks now continue through that Z-owned path
into the matching WebView. The frontend API deliberately mirrors the backend's
subscription vocabulary and lifecycle:

```ts
import { WindowEvent } from "@zappdev/runtime/window";

const resized = window.subscribe(WindowEvent.RESIZE, ({ size }) => {
  renderSize(size.width, size.height);
});

resized.unsubscribe();
```

Delivery is window-scoped twice: native code evaluates the event only in the
originating window's WebView, and `WindowHandle.subscribe` filters the payload by
the handle identity. Z Notes renders per-window focus, blur, and resize counters
so this isolation can be exercised directly. Cancellable `closeRequested`
remains a synchronous Z-native event; asynchronous JavaScript observers cannot
veto an AppKit close and are not presented as though they can.

`@zappdev/runtime/window` talks directly to the narrow bridge for identity,
creation, actions, and subscriptions. It exports `currentWindow`,
`createWindow`, the implemented event vocabulary, and the narrow
`WindowHandle` contract without importing or exposing the legacy `Window`
implementation. Additional operations enter this boundary only after their
native Z path, permissions, lifecycle, and frontend behavior are proven end to
end.
Its event payloads mirror Z directly: resize carries `windowId` plus a
`WindowSize`, while position belongs to a future movement or bounds contract.
Dimensions are native content-region values in logical display units (macOS
points and Windows DIPs), never physical device pixels. Delivery timestamps are
not fabricated as native event data.

This boundary also has measured bundling evidence. Building the same Z Notes
frontend with Vite 8.2.2 produced a 40,280-byte JavaScript chunk (12,202 bytes
gzip) while the focused module delegated through the legacy window runtime.
The direct bridge implementation produces 17,773 bytes (5,846 bytes gzip): a
55.9% raw and 52.1% gzip reduction without changing application behavior.

The Objective-C host owns the process/run-loop adapter, native service-response
delivery, and smoke observation rather than application object construction or
message-body validation. The WebKit custom-scheme controller and its request
policy are Z-owned: origin/path validation, SPA fallback, asset selection, MIME
and encoding choice, response construction, and task delivery all live in
`scheme-handler.zs`. The generated asset catalog is also Z: module-local
`embed.StaticBytes` values refer directly to process-lifetime compiler storage,
and raw assets become zero-copy `NSData` views. Native glue only decodes Brotli
bytes into an ownership-transferring `NSData`. Z constructs typed Foundation
errors and fails WebKit scheme tasks directly.
WebView bootstrap, identity, and configured CSS/JavaScript injection policy are
also Z-owned in `webview-injections.zs`: profile validation, duplicate
suppression, JSON-safe source quoting, phase mapping, and `WKUserScript`
registration happen through checked Objective-C interop. The generated
`configured-webview.zs` module carries the origin, bundled bootstrap, and
ordered injection sources as ordinary typed Z values; production native glue
no longer exposes or reads a parallel C configuration table.
Initial URL resolution and compiled navigation-profile enforcement live in
`navigation.zs`. A retained Z-owned `WKNavigationDelegate` adapter handles
native completion blocks directly and checks both main-frame and subframe
requests. `"self"` resolves to the generated development or packaged origin;
additional HTTP(S) origins come from the selected immutable profile. The
window's typed Z `navigationRequested` event may only cancel a profile-approved
request. The focused TypeScript event is a read-only observation delivered
after the native decision. Frontend-created windows inherit their creator's
profile, and neither a denied navigation nor `target="_blank"` implicitly opens
an external application.
The `WKScriptMessageHandler` independently validates `WKFrameInfo` before
reading the message body: only the main frame whose request has the generated
frontend origin may enter decoding and routing. This keeps navigation,
injection, and bridge authority distinct and blocks raw script-message calls
from same-origin or remote subframes.
Window request construction, loading, centering, and initial visibility are
also ordinary checked Z/AppKit calls rather than host-side Objective-C policy.

The consuming `Application` also owns a separate lifecycle registry. Typed
main-executor start hooks run before the blocking platform loop; stop hooks run
after it returns. Startup failure rolls back the successfully started prefix in
reverse order, while normal shutdown attempts every stop before propagating a
typed lifecycle error. Ordinary owned service resources still prefer `deinit`;
the explicit lifecycle contract is for process-wide orchestration.

Run the focused end-to-end paths with:

```sh
bun run spike:z-bridge
bun run spike:z-notes
bun run spike:z-notes:smoke
bun run spike:z-notes:dev
bun run spike:z-notes:dev-smoke
```

The Z Notes development runner uses the fixed-point native `z` driver. Manual
`TaskScope` construction, owned capture transfer, main-executor placement, and
scope close/join are all native-backed; no Stage 0 override is required.

The strict bridge smoke imports `compileNative`, sets the same language selector
as the CLI, builds the in-tree core, links it, and routes a non-ASCII JSON
envelope with request ID `u64.max`. It verifies the typed response metadata and
exact JSON payload after the C -> Z -> C round trip. It is therefore evidence
for the real build seam rather than a parallel script that can drift from it.

The ordinary Z Notes command builds the default host, injects the production
bootstrap and generated service facade at document start, and dynamically opens
a second diagnostics window through `createWindow()`. The local runner launches
the result from an ad-hoc-signed development `.app`, giving bundle-sensitive
native frameworks the same process identity shape as a packaged application.
The process stops only after the last native
window closes. Clicking either window's visible button calls
`notes.create(...)`; native delivery resolves it through `_onInvokeResult()`
and the binding restores the exact `u64` identifier as `bigint` before updating
the DOM. `spike:z-notes:smoke` opts into bounded automation: it verifies
independent window identities, frontend-safe injection isolation,
cancellation/request routing, non-prompting native notification status, and
both DOMs before closing every window. Both
use the same staged native inputs and generated Z asset catalog as an ordinary
`ZAPP_NATIVE_LANG=z` build.

The development commands exercise the complete CLI-owned loop: Vite serves the
same logical application URL with its HMR client, the Z-native AppKit/WebKit
host loads it, and closing the app deterministically terminates and awaits the
detached Vite process tree. The bounded smoke distinguishes `hmr=ready` from
the packaged `hmr=packaged` path and verifies that port 5173 is reusable after
shutdown.

The focused `native/z/smokes/async-service/` executable proves the same service
shape without involving WebKit timing. It routes the synchronous health path,
the suspended `AsyncServiceHandler` path, and a deterministic cancellation
path under one `TaskScope`. The cancellation target parks in scheduler-aware
`delay`; cancelling its recorded `TaskControl` removes the timer and proves the
post-delay continuation never executes, while a later service request still
completes. Stage 0 and the fixed-point compiler execute the same smoke.
Synchronous handlers remain in a separate frozen map and retain the direct-call
path.

The desktop application applies that model to a foreign WebKit callback. An
application-owned `TaskScope` accepts each request, keeps it alive through
service suspension, publishes completion on `thread.main`, and is cancelled
and joined before lifecycle shutdown. A main-isolated registry maps WebView
request identifiers to generation-guarded `TaskControl` values; mutable request
objects never cross a task boundary. `CancellablePromise.cancel()`, timeouts,
and standard `AbortSignal` requests therefore reach the corresponding
structured Z task. Cancellation remains cooperative: the browser rejects
immediately, the Z task observes cancellation at a supported suspension point,
and the browser ignores any completion that already won the race.

The routing helper itself is executor-neutral. It awaits the selected service
without claiming UI affinity, then explicitly uses
`await on thread.main finishAndDeliverRoutedResponse(...)` for generation
bookkeeping and native WebView delivery. WebKit currently enters this path on
main, so publication takes the zero-hop fast path. The same router can later be
started on a worker executor without making service code or response decoding
implicitly main-isolated.

## Compiler contract

Z reports an identity shaped like:

```text
z 0.1.0-dev revision 2026-08-31.1 compiler-api 2
```

The language version describes the user-facing language, the compiler revision
is deliberately bumped when Zapp must revalidate compiler behavior, and the API
revision describes the build/embedding contract. This is more useful than
pinning every unrelated Z Git commit and more reproducible than trusting an
executable path. Any mismatch fails before compilation with the observed and
expected values.

## Phase 0 performance checkpoint

Measured on the existing Apple M4 Max development machine, using the release Z
library and a size-optimized strict-C host:

| Metric | Phase 0 result | Meaning |
|---|---:|---|
| Z archive | 4,384 bytes | One exported owned-string route plus embedding runtime |
| Linked lifecycle host | 51,176 bytes | Console smoke only; no AppKit/WebKit or assets |
| Clean staged smoke | 373.6 ms mean, 35.3 ms standard deviation | Five runs, stage removed before each run |
| Cached staged smoke | 314.1 ms mean, 24.8 ms standard deviation | Ten runs after two warmups |

These are the historical pre-JSON baseline numbers, not a product comparison.
The runtime-owned typed JSON archive is 43,704 bytes. Its strict-C smoke host is
71,224 bytes, while the first dynamically linked AppKit/WebKit executable is
95,760 bytes. The current like-for-like Z Notes product checkpoint is a 281,920
byte executable, a 290,816 byte icon-free application bundle, 24 MB idle RSS,
and a 79 microsecond median no-op WebView service round trip. The typed struct
echo probe measures 80 microseconds, so generated DTO handling adds about one
microsecond at this boundary. Z must continue to report clean and incremental
build time, binary and bundle size, idle memory, startup, bridge latency,
allocations/copies, and deterministic shutdown against equivalent applications.

The first typed-service checkpoint adds a frozen function-valued router,
checked Notes handler, synchronized service state, exact integer projection,
and direct embedded-host entry. The measured release strict host grows from
71,216 to 89,168 bytes; its Z archive grows from 43,552 to 56,592 bytes. Three
100,000-call direct `notes.count` runs measured 279.44, 258.85, and 257.00 ns per
call, including lookup, thunk invocation, synchronized read, JSON response, and
C callback. See [Z-owned services](./z-services.md) for the architecture and
measurement boundary.

## CLI and package design are open

The existing command and npm layout are not compatibility constraints. Phase 0
keeps `zapp build` as a stable measurement harness, but the rewrite may improve:

- package boundaries between CLI, runtime, Vite integration, native sources,
  and compiler/toolchain metadata (the repository now declares those existing
  packages as Bun workspaces so one install is authoritative);
- dependency ownership (the Vite plugin now declares its own Babel/esbuild
  runtime surface instead of resolving it accidentally through the CLI);
- staging and incremental native caches;
- compiler acquisition and reproducible toolchain selection;
- generated-binding ownership and diagnostics; and
- the stable package import that replaces the spike's repository-relative
  framework import.

Changes should reduce concepts and generated glue, preserve Bun-friendly
frontend ergonomics, and remain measurable. We do not need to imitate the old
CLI merely because it exists.

## Next exit criterion

Phase 0's exit criterion is satisfied. Phase 1 now has a visible generated
service call through WebView -> Z -> WebView, a generated-runtime-owned Z
`Application`, Z-owned UI identities and retained protocol registration, typed
JSON ingress and dispatch, an embedded-engine direct-service seam, and
deterministic window/run-loop/runtime shutdown. The framework and application
are now separate source graphs, and one Notes project drives dynamic
multi-window WebViews and the strict-C embedding host. The first compiled
permission slice also gates frontend window creation inside Z and returns
structured invocation errors that the TypeScript runtime restores as
descriptive error subclasses. Generated services now preserve owned decoded
request values and typed failures through suspension and explicit main-executor
placement. Synchronous main-isolated service methods are adapted through a
private generated async wrapper, keeping the public method synchronous while
making cross-executor dispatch explicit in generated Z. Remaining work includes
zjs host attachment, broader wire-type coverage, and ASan or equivalent leak
evidence on a compatible host.
