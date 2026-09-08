# Application activation

Zapp delivers OS reopen requests and registered custom URLs to application-owned
Z events. Application code decides what those requests mean. This is distinct
from WebView focus events, outgoing `app.shell.openExternal(...)`, and WebView
asset protocols.

## Configure and subscribe

```ts
// zapp.config.ts
application: {
  name: "Z Notes",
  identifier: "com.example.notes",
  deepLinks: ["znotes"],
}
```

Schemes are case-insensitive and written without `://`. Duplicate schemes,
invalid names, and built-in `http`, `https`, `file`, `data`, or `javascript`
schemes are rejected. The same configuration generates the bundle registration
and the native allowlist; omitting it accepts no URL schemes. Registration does
not guarantee OS-wide exclusivity: another application may register the same
scheme. Target a particular app bundle when testing.

The CLI publishes a complete signed bundle and refreshes its macOS registration
after replacement. This matters when a rebuild changes the executable name or
bundle identity: launching by bundle path must not reuse a stale executable.
Smoke-test bundles are isolated from the interactive bundle and do not advertise
the application's custom URL schemes.

The subscription pattern inside application setup is:

```zs
import {
  ApplicationOpenURLRequestedEvent,
  ApplicationReopenRequestedEvent,
} from "zapp";

const reopen = try app.events.reopenRequested.subscribe(
  move (in event: ApplicationReopenRequestedEvent): void => {
    window.show();
  }
);

const links = try app.events.openURLRequested.subscribe(
  (in event: ApplicationOpenURLRequestedEvent): void => {
    // Validate event.url and route it to an app-owned operation.
    // Avoid logging arbitrary URLs: they may contain credentials.
    console.log("Received an application URL request");
  }
);

// Keep subscription owners alive across app.run(). Their deinit unregisters
// the listeners; unsubscribe() is available for earlier removal.
```

`ApplicationReopenRequestedEvent` has no payload in this tier.
`ApplicationOpenURLRequestedEvent` is a readonly value containing an owned
`url: String`. Multiple subscriptions are independent and invoke in registration
order. Callbacks are synchronous and main-executor-bound. As with other Z events,
copy data needed by separately scheduled async work rather than retaining a
borrowed callback parameter.

## Delivery and lifetime

- The native delegate is installed before windows are constructed.
- Inputs received during setup are queued. Delivery begins after native windows,
  managers, and synchronous service startup have completed. This does **not**
  promise that a WebView DOM is ready or that independently scheduled startup
  work has finished.
- Startup and running requests use the same event source. Accepted inputs are
  delivered FIFO; a reentrant request waits behind already accepted requests.
- Buffering is limited to **64 pending requests**, with a **16 KiB UTF-8 limit
  per URL**. The macOS adapter also limits each incoming batch to 64 entries.
  Excess or invalid input is rejected with a diagnostic that omits URL contents.
- There is no durable inbox or late-subscriber replay. If no listener is present
  when a ready event is delivered, the event is not retained for a future one.
- Accepted quit, failed startup cleanup, and final shutdown discard queued
  requests and finish the activation event sources. A cancelled quit leaves them
  available. Dispatch stops safely if a callback closes its event source.

Unlike `quitRequested`, neither event exposes `cancel()`: Zapp has no default
navigation, window creation, or service invocation waiting to happen. Ignoring
the request does nothing. Reopen delivery suppresses AppKit's default window
handling; the application chooses which window to show or restore.

## Trust and scope

A URL is untrusted input, not permission to access a file or invoke a service.
The first tier delivers it to native Z only. It is not broadcast to every
WebView or worker, where it could expose credentials or unrelated application
state. Application code validates the route and chooses a destination.

Z Notes demonstrates that separation in `notes-route.zs` and
`notes-activation.zs`: only `znotes://notes/<u64>` is accepted, the note must
exist in the started service, and native code constructs its own relative
`/notes?note=<validated-id>` window URL. The frontend highlights that note.

## Secondary-instance payload foundation

The event source and checked payload codec are implemented:

```zs
export readonly struct ApplicationSecondInstanceLaunchedEvent {
  arguments: readonly Array<String>;
  workingDirectory: Option<String>;
}
```

`app.events.secondInstanceLaunched` uses the same synchronous main-executor
subscription and shutdown rules as the other activation events. Arguments
exclude the executable name and preserve empty strings, whitespace, and UTF-8;
they are not shell-parsed. The working directory is an optional owned snapshot,
not a directory change for the primary process. Treat both as untrusted input.
A URL-looking argument does not also emit `openURLRequested` or
`reopenRequested`.

The private version-1 envelope nests this snapshot directly. Z's derived JSON
codec handles the readonly array and `Option<String>`; `null` means no working
directory, while a missing key is malformed. No flattened duplicate record or
array-copy adapter is needed. Limits are 256 arguments, 16 KiB per argument or
working-directory string, and 64 KiB for both aggregate input text and the
encoded envelope. Embedded NULs, an empty present working directory, duplicate
fields, malformed JSON, and unsupported versions are rejected. Error messages
do not include argument contents. Launches share the existing 64-request FIFO.

This is the **payload and event foundation**, not automatic cross-process
delivery yet. The private primary lease and forwarding transport are tested
independently below; wiring them into startup and shutdown awaits the async
composition prerequisites described below. The existing bundle hint alone does
not provide those guarantees.

The transport admits into the **same 64-request inbox** used by OS
activation. An acknowledgement means bounded admission, not that a listener
ran or that delivery is durable. Native callback threads must not invoke app
listeners while holding the inbox mutex. Shutdown closes admission before
transport teardown; a cancelled quit keeps it open.

This exposed an upstream Z prerequisite: independently owned lock-callback
results now execute in both compilers, including Options and typed failures.
Transferring an owned outer capture into a known-once `Mutex.withLock` callback
is now approved and implemented upstream. The private `ActivationInbox` owns
the existing ring budget behind a `Mutex`; OS events and secondary-launch
admission use the same queue. A readonly ARC handle may be retained by a
producer thread, but it grants only admission, not main-bound event access.
`take()` transfers one owned request out before listeners run. Early rejection
destroys the unused incoming request, and closing the inbox discards pending
requests while existing producer handles remain safely closed.

The private macOS transport below now forwards and acknowledges admission in
isolated processes. It is not installed by `app.run()` yet. Native owned async
destructuring and the ordinary suspending-helper tier need upstream work before
startup/shutdown integration and competing-launch/teardown race tests.
Acknowledgement remains admission, not listener completion or durable delivery.

`native/z/tests/application-launch-smoke.zs` verifies the codec, limits,
independent event delivery, reentrancy, unsubscribe, and shutdown behavior
through Stage 0 and native Z.

`native/z/tests/activation-inbox-producer-smoke.zs` checks three concurrent
producers against the single 64-request capacity in both compilers, including
one mutex-protected wake reservation across all producers. Clearing the pending
reservation before draining allows a concurrent producer to reserve a later
wake without losing notification; closing admission clears it and prevents
further reservations. This primitive is not yet connected to main dispatch.
`native/z/tests/activation-inbox-smoke.zs` additionally checks main-executor
listener delivery, FIFO reentry, capacity reuse, cancelled quit, and rejection
after shutdown. Its combined async event setup currently executes through
Stage 0; the native emitter's broader suspending-statement composition remains
a tracked boundary, not a separate framework implementation. The synchronous
activation/launch smokes retain native coverage of event delivery and teardown.

### Private primary-ownership checkpoint

The macOS backend now has an internal move-only instance lease, not yet called
by `app.run()`. It uses a nonblocking exclusive OS file lock per effective user
and exact application identifier. Stable SHA-256 filename encoding avoids path
interpretation and filesystem-name length restrictions; it is not an
authentication mechanism. The lock lives beneath the OS-reported private user
temporary directory, not an environment-supplied `TMPDIR`. Directory and file
ownership, permissions, type, link count, and symlink traversal are checked.
This follows Apple's [private temporary-directory guidance](https://developer.apple.com/library/archive/documentation/Security/Conceptual/SecureCodingGuide/Articles/RaceConditions.html).

The Z owner's `deinit` closes the descriptor. The kernel also releases the lease
after process death; close-on-exec prevents an executed child program from
retaining it. Lock files are deliberately **not deleted** during normal use:
replacing the inode could let two processes lock different files under one
name. Empty files are harmless, not evidence of a live or stale primary. There
is no PID guessing, stale-file takeover timeout, polling, or background thread.

Contention is distinct from setup failure. A future startup integration must
forward to the owner or report failure; it must not treat an I/O failure as
permission to start a second application. This is cooperative same-user
coordination, not a security boundary against other code running as that user.
It does not yet prove that the owner has a ready endpoint or accepted a launch.

### Private bounded transport checkpoint

`platform/macos/instance-transport.zs` owns framing, deadlines, typed failures,
and admission in Z. `launch-socket.zs` isolates the OS socket and native byte
buffer operations. No application listener or WebView operation runs on the
transport path. No new public application API or configuration is added.

The move-only endpoint consumes the primary lease and derives its name from
that lease's exact identifier. Its static factory is the only way to initialize
its private fields. Teardown removes the socket and closes its descriptor
before field cleanup releases the lease. A successor holding that lease may
remove a stale socket left by process death; the stable lock file is never
removed. A process without the lease cannot install an endpoint through this
API.

The transport uses a local Unix stream socket beneath the checked mode-0700
directory `/private/tmp/zapp-launch-<effective-uid>`, with a full SHA-256 filename
and a mode-0600 socket. This short, canonical location fits Darwin's Unix-socket
path limit without truncating the identity or trusting `TMPDIR`. Symlinks,
wrong ownership, non-socket files, and permissive endpoint modes fail closed.
Both peers check the effective UID using
[`getpeereid`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/getpeereid.3.html).
This is cooperative same-user coordination, not authentication against other
programs running as the same user. App Sandbox/Mac App Store packaging and other
platform transports still need separate validation.

Each connection carries one four-byte big-endian length followed by the existing
UTF-8 JSON launch envelope. Request length is checked **before** allocating the
body and is limited to 64 KiB. Replies are length-framed too, limited to 64 bytes,
and must be exactly `zapp-launch/1 accepted` or `zapp-launch/1 rejected`.
Malformed UTF-8/JSON and full/closed inboxes receive rejection; malformed or
incomplete framing closes the connection without admission. Socket setup asks
for a backlog of 16; the receiver services one connection at a time and the
application's shared pending queue stays limited to 64 requests.

Nonblocking I/O uses monotonic absolute deadlines: at most one second to wait
for a connection, one second for that connection's request/response, and five
seconds for the client's complete connect/send/receive exchange. Partial reads,
writes, and interruptions do not reset these deadlines. These are private first-
tier limits, not a new user configuration surface. Socket writes suppress
`SIGPIPE`, so a disconnected peer becomes a typed error instead of terminating
the application.

| Client outcome | Meaning |
| --- | --- |
| `true` | The primary acknowledged admission into the shared inbox. |
| `false` | The primary explicitly rejected this request. |
| Error, `mayHaveBeenAdmitted: false` | Failure before a request could be sent. No secondary primary is started. |
| Error, `mayHaveBeenAdmitted: true` | Sending began but no valid final acknowledgement arrived. Admission may already have happened. |

The transport never resends a request automatically. Its private readiness mode
may retry only transient connection failures **before sending**, while a newly
elected primary is publishing its endpoint. Each pause is at most ten
milliseconds, with no busy spin, and consumes the same five-second exchange
deadline. Invalid ownership, permissions, or path shape fail immediately.
An elected primary that never becomes ready produces failure, not promotion of
the secondary into another primary. A timeout or broken connection after
sending does not prove non-delivery, and blindly resending could produce
duplicate application events. Accepted input remains best effort:
shutdown may discard it after acknowledgement. Future startup integration must
distinguish election, endpoint readiness, admission, and teardown rather than
turn every transport failure into another primary.

Run both compiler paths against real, isolated processes:

```sh
bun run cli/src/test-instance-transport-macos.ts
# Optional undefined-behavior instrumentation of both generated executables:
ZAPP_LAUNCH_UBSAN=1 bun run cli/src/test-instance-transport-macos.ts
```

The suite verifies sequential/concurrent capacity, acceptance without a main
loop or listener, closed admission, fragmented input, invalid lengths and UTF-8,
absolute slow-client deadlines, delayed/absent endpoint readiness while the
primary retains its lease, missing/corrupt/oversized acknowledgements with no
resend, scope cleanup, contention, crash recovery, and hostile endpoint paths. Children
have watchdogs; only run-unique socket/lock names are removed after all children
stop. Interactive application bundles are never launched by this regression.

### Integration prerequisite and continuation

The attempted lifecycle-owned listener exposed two upstream Z boundaries:
ordinary owned struct destructuring inside async frames, and native execution
of an ordinary named helper with `await scheduler.yield()` inside a loop.
Stage 0 now executes the first shape, with cleanup verified on success, error,
and cancellation, including awaited initializers and joined scoped borrows.
Owned branch/loop bindings still require explicit lexical async scopes. The
reduced cases are recorded in Z's ownership-pressure log and
`async-launch-owned-destructure.zs` / `async-launch-listener.zs` fixtures. Both
now execute through the fixed-point native compiler too. Its new yield frame
retains root Z-owned locals and selected fields across `if`/`while` yields,
with cancellation-before-entry and post-initialization cleanup tests. Ordinary
owned Z-value parameters now enter that cold frame before the body runs, with
drop-before-poll and cancellation cleanup. Implicit ARC arguments preserve the
caller's alias; explicit `move` transfers it. The frame now also admits the
real listener's Foundation-backed endpoint and synchronized inbox, including
its nested readonly launch arguments. The transport regression compiles a
bounded, unstarted `retainLaunchFrame` helper against those actual types through
both compilers. Z's separate runtime tests check descriptor release, reverse
endpoint/lease cleanup, and unlocked Mutex state on cold drop and cancellation.
Clang strong slots in heap frames are explicitly cleared even for wrappers
without a Z `deinit`. The upstream `void`/`i32` frame now also supports typed
errors, repeated direct named child awaits with owned arguments, root owned
child results, and `try`/`attempt`. Cancellation joins an active child before
destroying its parent; owned-error tests cover unclaimed results and Foundation
strong fields. The actual endpoint probe now also compiles a synchronous
`match (attempt endpoint.receive(in inbox))` inside its yielding loop. It tracks
both acknowledged admission and admission followed by an acknowledgement error.
Upstream runtime probes cover payload cleanup on fallthrough, early return,
throw/`try`, loop exits, and cancellation, including Foundation ARC payloads.
Borrowed child arguments, method/placed awaits, and nested awaited expressions
remain outside this loop tier. Match arms cannot suspend in this tier; their
payloads finish before the next yield. This is not a running listener.

The next step is to pressure-test main-host wakeup placement and joins against
those remaining boundaries, then restore the
integration probe. Do not infer integration from the reduced compiler tests.
The listener will construct/destroy the endpoint on its own worker,
observe cancellation between bounded receives, and send only inbox wakeups to
the main-owned host. Startup must distinguish election from endpoint readiness
and admission. Shutdown must close admission, cancel/join the listener, release
the endpoint before its lease, and join pending main work before destroying the
host. Do not replace that with a synchronous endless worker whose exit depends
on cleanup in the parent that is already waiting to join it.

No new public application API, configuration field, or language syntax was
introduced by this prerequisite work. The existing application path remains
unchanged until cancellation, startup failure, competing launches, and teardown
have executable integration coverage.

Run the separate bounded primary-lease regression with:

```sh
bun run cli/src/test-instance-lease-macos.ts
```

It builds the same isolated fixture through Stage 0 and the native Z driver,
then checks scope cleanup, competing processes, independent identities, crash
recovery without removing the lock, simultaneous launches, and hostile file
shapes. Every child has a deadline and teardown; interactive bundles and their
instance identifiers are not used. `Z_SOURCE_ROOT` can select the compiler
checkout (the default is the sibling `z-lang` directory).

Current application integration: macOS `NSApplicationDelegate` reopen and
`application:openURLs:` callbacks. File associations, universal links, frontend
event delivery, and automatic cross-process single-instance forwarding remain
future integration. The existing `singleInstance` bundle hint is not a portable
forwarding protocol or a guarantee against direct executable launches.

See [Z Notes](../spikes/z-notes/README.md#application-activation) for manual and
bounded regression probes.
