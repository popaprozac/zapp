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
delivery yet. The private primary-ownership primitive is tested independently
below; wiring it into startup, admission acknowledgements, forwarding, and
shutdown races are the next runtime slice. The existing bundle hint alone does
not provide those guarantees.

`native/z/tests/application-launch-smoke.zs` verifies the codec, limits,
independent event delivery, reentrancy, unsubscribe, and shutdown behavior
through Stage 0 and native Z.

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

Run the bounded native regression with:

```sh
bun run cli/src/test-instance-lease-macos.ts
```

It builds the same isolated fixture through Stage 0 and the native Z driver,
then checks scope cleanup, competing processes, independent identities, crash
recovery without removing the lock, simultaneous launches, and hostile file
shapes. Every child has a deadline and teardown; interactive bundles and their
instance identifiers are not used. `Z_SOURCE_ROOT` can select the compiler
checkout (the default is the sibling `z-lang` directory).

Current platform implementation: macOS `NSApplicationDelegate` reopen and
`application:openURLs:` callbacks. File associations, universal links, frontend
event delivery, and cross-process single-instance forwarding remain future
contracts. The existing `singleInstance` bundle hint is not a portable
forwarding protocol or a guarantee against direct executable launches.

See [Z Notes](../spikes/z-notes/README.md#application-activation) for manual and
bounded regression probes.
