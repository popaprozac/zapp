# Z host SDKs and WebView IPC

Status: accepted architecture direction; not yet an implemented or stable API,
August 2026.

Zapp's smallest and most capable first-party path remains a Z application linked
directly with the Z native core. The same core should also be consumable as a
versioned C ABI library, tentatively `libzapp`, so other language runtimes can
choose their own size, memory, and ecosystem tradeoffs without reimplementing
windows, WebViews, services, permissions, lifecycle, or platform integration.

The first important alternative host is Bun. A Bun application deliberately
accepts Bun's runtime and distribution cost in exchange for TypeScript, Bun
APIs, and npm compatibility. That is an optional compatibility tier, not the
baseline cost of a Zapp application.

## Layering

```text
WebView application TypeScript
        |
        | generated typed service proxies
        v
document-start Zapp bridge
        |
        | WKWebView / WebView2 / WebKitGTK message API
        v
libzapp
  - validates origin, view identity, capabilities, and protocol version
  - owns the platform WebView adapters and event queues
  - routes native Z services directly
  - routes external-host services through the C ABI
        |
        | batched, framed C ABI transport
        v
@zapp/bun
        |
        | generated service dispatch
        v
Bun application services
```

The page never knows which main-process language implements a service. Bun
never knows whether the current platform uses AppKit/WebKit, WebView2, or
WebKitGTK. `libzapp` is the only layer that understands both the portable
message protocol and the platform bridge.

## Intended application surface

The WebView imports generated bindings rather than authoring stringly typed
`invoke` calls:

```ts
import { notes } from "zapp:services";

const note = await notes.create({ title: "First note" });
```

A Bun host registers an ordinary implementation and awaits the application
lifecycle:

```ts
import { Application } from "@zapp/bun";
import { NotesService } from "./notes-service";

const app = new Application({
  name: "Notes",
  frontend: "./dist",
});

app.services.register("notes", new NotesService());
await app.run();
```

The host surface follows the same ownership rule as native Z without requiring
identical syntax. Application-owned registries such as windows and services are
reached through the application instance; existing resources expose behavior
on their handles; stateless operating-system capabilities should use focused
package imports. The WebView package is deliberately more TypeScript-shaped:
window creation crosses IPC and therefore uses an async factory returning a
proxy rather than a synchronous constructor with a hidden global application.

This split takes inspiration from Wails' discoverable application managers
while avoiding a universal manager tree. The application object should expose
only capabilities whose identity or lifecycle it genuinely owns.

The build owns the service manifest, stable numeric route identities, WebView
proxies, Bun contracts, encoders, and decoders. Application authors should not
write per-method bridge adapters.

## Portable request model

All service calls are asynchronous even when their current implementation is
synchronous. One request carries at least:

```text
protocol version
message kind
view identity
request identity
route identity
flags
payload length
payload bytes
```

The protocol needs structural variants for request, successful response,
failed response, cancellation, event, subscribe, and unsubscribe. Explicit
request identities give every platform the same Promise behavior even when a
native WebView offers a platform-specific reply handler.

JSON is the first portable WebView-edge representation. It must remain an edge
format rather than Zapp's internal object model. The native-to-host ABI should
use framed byte batches so `libzapp` can route messages without parsing
application payloads. Generated binary payload codecs may replace JSON later
without changing application service APIs.

## Wake, queue, and drain

`libzapp` must not synchronously enter arbitrary Bun service code from a
WebView, AppKit, WebView2, or foreign-thread callback. It copies validated
messages into an owned queue, issues a one-way wake notification, and returns
to the platform immediately.

The Bun SDK schedules work on Bun's JavaScript executor and drains one or more
events through a narrow ABI. A representative shape is:

```c
typedef struct ZappApplication ZappApplication;
typedef void (*ZappWakeHost)(void *context);

void zapp_set_wake_callback(
    ZappApplication *app,
    ZappWakeHost callback,
    void *context
);

size_t zapp_drain_events(
    ZappApplication *app,
    uint8_t *destination,
    size_t capacity
);

int32_t zapp_send_responses(
    ZappApplication *app,
    const uint8_t *bytes,
    size_t length
);
```

This is illustrative, not locked ABI spelling. The required properties are:

- the wake callback is one-way and carries no borrowed payload;
- `libzapp` owns queued bytes until the host explicitly drains them;
- the host supplies buffers or receives an ownership-bearing event handle;
- batching amortizes FFI and executor crossings;
- queues are bounded and expose backpressure;
- no native pointer becomes an application-visible JavaScript value; and
- shutdown cancels pending requests, drains or rejects completions, closes
  callbacks, joins native work, and destroys the application deterministically.

The same transport can back Bun, Node-API, zjs, Go, Rust, Nim, or another C ABI
host. A host may provide a more direct adapter, but it must preserve the same
request, cancellation, ownership, and shutdown semantics.

## Event-loop ownership

A blocking `zapp_run()` invoked through Bun FFI would stop Bun timers,
Promises, networking, and service handlers. The host contract therefore needs
a nonblocking start plus wake-driven integration with the host executor and the
platform UI loop. A polling adapter is acceptable as a narrow spike, but not as
the production latency or power model.

On macOS, every UI operation remains main-executor-bound. The Bun adapter must
integrate Bun progress with the AppKit run loop without moving AppKit objects
off the process main thread. Windows and Linux adapters must provide equivalent
wake behavior without leaking their platform primitives into the portable SDK.

The public Bun API remains `await app.run()`: it resolves after native shutdown
and cleanup, not when the window is merely created.

## Cancellation, events, and streams

Frontend cancellation sends a protocol cancellation frame. The Bun SDK maps
the request identity to an `AbortController` or equivalent service context.
Responses arriving after cancellation are dropped deterministically.

Events use explicit subscription identities. Unbounded fire-and-forget event
queues are not permitted. Streams require credits, acknowledgements, or another
bounded backpressure contract.

Large files, images, and media should not be base64-encoded through ordinary
RPC. Prefer an opaque resource handle or a `zapp-resource://` URL that lets the
WebView stream bytes directly from the native resource provider. Data should
only cross Bun when a Bun service actually produces or transforms it.

## Security boundary

Every inbound WebView request is associated with its originating view, frame,
navigation origin, protocol version, and granted capability set. Remote content
receives no bridge by default. Each window exposes an allowlisted service
surface, message sizes are bounded, schemas are checked, and arbitrary method
names, native pointers, and general-purpose evaluation never become RPC
capabilities.

A versioned service-manifest hash should participate in the startup handshake
so incompatible generated frontend and host bindings fail immediately rather
than misrouting numeric method identities.

## Distribution direction

A Bun release contains a Bun-compiled main executable plus the platform
`libzapp` image and ordinary application resources. The recommended production
shape is a normal signed application bundle or installer, not reliance on
temporary extraction performed implicitly by a runtime:

```text
macOS:   MyApp.app/Contents/MacOS/MyApp
         MyApp.app/Contents/Frameworks/libzapp.dylib

Windows: MyApp.exe
         zapp.dll

Linux:   myapp
         lib/libzapp.so
```

The download may still be a single DMG, installer, archive, or self-extracting
artifact. If a future single-executable mode embeds the native library, Zapp
should extract it to a deterministic content-addressed cache, verify it, reuse
it across launches, and clean obsolete versions deliberately.

## Performance rules

The system-WebView process crossing is usually more consequential than the
in-process C ABI call. Keep service operations coarse, batch host events, avoid
repeated property-shaped FFI calls, and measure serialization, copies,
allocations, wake latency, queue depth, and end-to-end round trips separately.

The Z-native host remains the size and performance reference. Bun is an
explicit ecosystem tradeoff. Both hosts must run the same service semantics and
representative bridge benchmark so convenience does not conceal transport
regressions.

## Work to prove before stabilizing

1. Export the minimum callback, queue, application-handle, and buffer ownership
   shapes through Z's checked `export c` surface.
2. Prove one nonblocking Bun host on macOS without timer polling as the final
   mechanism.
3. Round-trip a generated typed service through WebView -> `libzapp` -> Bun ->
   `libzapp` -> WebView.
4. Add cancellation, shutdown with pending work, bounded queues, and a large
   payload/resource-stream probe.
5. Measure the same application under Z-native, Bun FFI, and any Node-API
   adapter retained for production stability.
6. Repeat the transport contract on Windows and Linux before declaring the ABI
   portable.
