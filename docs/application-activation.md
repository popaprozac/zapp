# Application activation (Z rewrite)

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

Current platform implementation: macOS `NSApplicationDelegate` reopen and
`application:openURLs:` callbacks. File associations, universal links, frontend
event delivery, and cross-process single-instance forwarding remain future
contracts. The existing `singleInstance` bundle hint is not a portable
forwarding protocol or a guarantee against direct executable launches.

See [Z Notes](../spikes/z-notes/README.md#application-activation) for manual and
bounded regression probes.
