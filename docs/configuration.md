# Zapp configuration

`zapp.config.ts` is Zapp's typed, build-time configuration surface. It owns
application metadata, frontend build inputs, WebView construction facts,
worker declarations, security policy, native build additions, and target
packaging settings.

It is intentionally separate from `z.json`, which belongs to the Z language
and package toolchain.

## Minimal configuration

```ts
import { defineConfig } from "@zappdev/cli/config";

export default defineConfig({
  application: {
    name: "Z Notes",
    identifier: "com.example.z-notes",
    version: "0.1.0",
  },
});
```

Only `application.name` is required. Zapp derives a stable
`com.zapp.<name-slug>` identifier and uses version `0.1.0` when those values are
omitted. It also supplies defaults for the frontend asset directory,
development port, system WebView, and asset compression.

## Complete shape

```ts
export default defineConfig({
  application: {
    name: "Z Notes",
    identifier: "com.example.z-notes",
    version: "0.1.0",
    singleInstance: true,
    deepLinks: ["znotes"],
  },

  frontend: {
    assets: "./dist",
    devServer: { port: 5173 },
    compressAssets: true,
  },

  webview: {
    engine: "system",
    protocols: ["asset"],
    preferences: {
      autoplayWithoutUserGesture: false,
      backForwardNavigationGestures: false,
    },
    inject: {
      base: {
        styles: ["./src/injected/base.css"],
        documentStart: ["./src/injected/preload.ts"],
      },
      diagnostics: {
        documentEnd: ["./src/injected/diagnostics.ts"],
      },
    },
  },

  security: {
    permissions: ["clipboard:read", "notifications", "window:create"],
    capabilities: {
      default: {
        permissions: ["window:create"],
        services: ["notes"],
      },
      diagnostics: {
        services: ["notes.count"],
      },
      backgroundSync: {
        services: ["notes.list", "notes.synchronize"],
      },
    },
    filesystem: {
      allow: ["$userData/**"],
      persistDialogGrants: true,
    },
  },

  workers: {
    // Runtime-module selection is provisional while ZJS is rewritten in Z.
    modules: ["fetch", "websocket"],
    application: {
      sync: {
        script: "src/workers/sync.ts",
        engine: "zjs",
        capabilities: ["backgroundSync"],
        protocol: {
          module: "./zapp/sync-worker-protocol.zs",
          type: "SyncWorkerProtocol",
        },
        restart: { maxRetries: 3, withinMs: 60_000 },
      },
    },
  },

  native: {
    frameworks: { macOS: ["CoreLocation"], iOS: ["CoreLocation"] },
    linkFlags: { macOS: ["-lsqlite3"], windows: ["-lws2_32"] },
    sources: { macOS: ["src/native/LocationAdapter.m"] },
  },

  targets: {
    macOS: {
      icon: "build/macos/icon.icon",
      minimumSystemVersion: "14.0",
    },
    iOS: {
      icon: "build/ios/icon.png",
      minimumSystemVersion: "17.0",
    },
  },
});
```

The platform spellings in authored maps are `macOS`, `iOS`, `windows`, and
`linux`. Misspellings such as `macos` fail validation instead of silently
dropping target-specific configuration. Target packaging blocks are exposed as
their implementations become real; macOS and iOS are currently typed.

`targets.macOS.minimumSystemVersion` is also the deployment floor for every
native object linked into the application, not only generated Z and Objective-C
source. During local development Zapp rebuilds the default sibling ZJS static
archive when its recorded deployment target differs from the application target.
An explicit `ZAPP_ZJS_LIBRARY` override remains an embedder-owned artifact and
must already be compatible with the configured floor. This prevents a seemingly
valid app target from silently linking worker-engine objects built for a newer
macOS release.

## Worker authority and lifetime

`workers.application` contains workers that start after registered services and
stop before those services during application teardown. Each map key is a
worker identity; its `capabilities` array selects trusted profiles declared
under `security.capabilities`.

The first native Z runtime tier is executable on macOS for source-module ZJS
workers. The build bundles each declared entry as one retained ES module,
embeds those bytes in the native core, starts the worker after service startup,
then requests cancellation and joins it before service shutdown. This is an
application lifetime, not a WebView lifetime: closing or replacing one window
does not implicitly destroy the worker.

When `restart` is present, the native ZJS runtime recreates a failed engine
context from the same embedded module. `maxRetries` is the number of
replacement incarnations allowed inside `withinMs`; both values must be
positive safe integers. Pending Z service work owned by the failed JavaScript
context is cancelled before replacement, while messages already accepted by
the bounded native inbox remain queued. Omit `restart` or set it to `false` to
make the first uncaught worker failure terminal.

That tier intentionally fails closed for other engines and ZJS bytecode. The
focused frontend facade already provides authorized send/subscribe and the
same generated service API inside workers. Native Z owns an `app.workers`
manager for configured application-lifetime workers. The safe default is
`get(ProtocolMarker())`, which returns a protocol-specific
`Option<ApplicationWorker<Command, Message>>`. Its `send(command)` accepts the
declared command enum, and its message stream yields
`Result<Message, ApplicationWorkerProtocolError>` so malformed native input is
never silently dropped. `getRaw(id)` and `all()` expose `RawApplicationWorker`
handles for diagnostics, migration, and intentionally undeclared channels;
their transport remains explicit `send(channel, payload)` and
`ApplicationWorkerMessage` values.

Both handle forms expose `state()`, focused lifecycle events (`started`,
`restarting`, `failed`, and `stopped`), plus an exhaustive `events.all` stream.
Native callback bytes are copied into immutable messages before subscribers run
on `thread.main`; subscribing in Z does not consume or suppress delivery to
authorized WebViews. Lifecycle and message subscriptions are multicast and
retain their registration for the lexical lifetime of their subscription.
Dynamic worker creation and WebView-owned worker lifetimes remain later manager
tiers rather than implicit behavior of this configured surface.

`protocol` is optional. Without it, `send(channel, payload)` and
`subscribe(channel, handler)` remain the explicit raw transport escape hatch.
With it, ordinary exported Z structs and enums become the checked source of
truth for both sides of the worker boundary:

```zs
import { WorkerProtocol } from "zapp/worker";

export readonly struct RefreshIndex {
  requestId: String;
}

export readonly struct IndexComplete {
  requestId: String;
  total: usize;
}

export enum SyncWorkerCommand {
  refresh RefreshIndex,
}

export enum SyncWorkerMessage {
  complete IndexComplete,
}

export type SyncWorkerProtocol =
  WorkerProtocol<SyncWorkerCommand, SyncWorkerMessage>;
```

The build checks that module with Z, requires the two protocol roots to be
exported enums, follows their exported payload graph, and generates
`zapp:workers`. WebView code receives a typed command namespace and one
discriminated message stream:

```ts
import { sync } from "zapp:workers";

await sync.commands.refresh({ requestId: "startup" });

const subscription = sync.messages.subscribe((message) => {
  switch (message.kind) {
    case "complete":
      console.log(message.value.total);
      break;
  }
});
```

The worker module imports the generated implementation helper from that same
module. It handles checked command payloads and can only publish message
variants declared by the Z protocol:

```ts
import { defineSyncWorker } from "zapp:workers";

const dispatch = defineSyncWorker({
  refresh(input, messages) {
    messages.complete({ requestId: input.requestId, total: 0 });
  },
});

export function onMessage(channel: string, payload: string): void {
  if (dispatch(channel, payload)) return;
  // Optional raw channels can coexist for diagnostics or benchmarking.
}
```

The marker has no runtime representation and adds no transport envelope. Enum
variant names become the existing native channel names; generated codecs
validate payloads and preserve exact 64-bit integers as decimal strings on the
wire. The same protocol drives native Z without duplicating channels or JSON
codecs:

```zs
const selected = app.workers.get(SyncWorkerProtocol());
const worker = match (selected) {
  some(value) => value;
  none => return 1;
};

try worker.send(SyncWorkerCommand.refresh(RefreshIndex({
  requestId: "startup",
})));

const subscription = try worker.messages.subscribe(
  move (in received): void => match (in received) {
    success(message) => match (in message) {
      complete(value) => console.log(value.total);
    };
    failure(error) => console.log(error.message);
  }
);
```

Use `app.workers.getRaw("sync")` only when intentionally working with a raw
channel/payload contract.

Capability selection is additive and frozen at build time. Omitting a worker's
`capabilities` grants no native permissions or service methods. Unknown and
duplicate profile names fail configuration loading. The generated native worker
metadata contains the fully expanded permission and service-method set, so
worker JavaScript never chooses its own authority.

`workers.modules` is deliberately separate. It currently selects optional
web-compatible runtime facilities for bare-engine adapters; it does not grant
native authority. Its exact vocabulary remains provisional while ZJS is
rewritten in Z and its compile-time feature trimming is pressure-tested.

## Contextual configuration

Configuration may be a synchronous or asynchronous factory:

```ts
export default defineConfig(async ({ command, mode, target, root }) => ({
  application: {
    name: target.os === "macos" ? "Z Notes" : "Z Notes Preview",
  },
  frontend: {
    devServer: { port: mode === "development" ? 5173 : 4173 },
  },
}));
```

The context contains:

| Field | Values |
|---|---|
| `command` | `"dev"`, `"build"`, or `"package"` |
| `mode` | `"development"` or `"production"` |
| `target.os` | `"macos"`, `"ios"`, `"windows"`, or `"linux"` |
| `target.arch` | `"arm64"` or `"x64"` |
| `target.environment` | `"desktop"`, `"simulator"`, or `"device"` |
| `root` | Absolute application project root |

Arbitrary TypeScript can choose and assemble configuration, but the returned
value must be plain serializable data. Functions, symbols, bigints, class
instances, cycles, non-finite numbers, and undefined array elements are
rejected with a configuration diagnostic.

## Resolution boundary

The CLI evaluates configuration once per command and writes the validated,
normalized contract to `.zapp/config.resolved.json`. Vite integration, native
code generation, packaging, and compiled application metadata consume that
snapshot. They do not import `zapp.config.ts` or independently execute its
logic.

The snapshot is generated build state, not a file applications should edit or
commit. Its schema is versioned independently from the ergonomic authoring
surface.

For Z-native applications, the same resolved identity is compiled into a
readonly `ApplicationMetadata` value. Security capabilities are compiled
separately into immutable application policy, so descriptive metadata never
becomes an authorization surface. `new Application()` receives both generated
values by default, and application source cannot replace policy with data from
a WebView.

At runtime the application combines that metadata with process arguments and
platform-resolved executable, resource, data, config, and cache paths in
`app.context`. These are runtime facts rather than authoring configuration and
therefore do not belong in `zapp.config.ts`.

Runtime behavior does not belong in configuration. Services, windows, menus,
lifecycle hooks, and mutable state remain ordinary Z source.

## Window capability profiles

`security.permissions` is the maximum built-in authority compiled into the
application. Named `security.capabilities` profiles narrow that authority and
registered Z services for each trusted native window:

```ts
security: {
  permissions: ["window:create"],
  capabilities: {
    default: {
      permissions: ["window:create"],
      services: ["notes", "health.status"],
    },
    diagnostics: {
      services: ["notes.count", "health.status"],
    },
    untrusted: {
      services: [],
    },
  },
},
```

A bare service selector such as `"notes"` grants every checked method on that
registered service. `"notes.count"` grants only that method. Unknown services
and methods fail the build against compiler-produced service metadata. A
profile cannot grant a built-in permission omitted from
`security.permissions`.

The first per-window framework-permission tier enforces `"window:create"`.
Other built-in permissions remain app-global and are rejected inside a profile
until their native routes carry originating-window context; this fails closed
rather than presenting a grant that is not actually enforced.

When an explicit catalog exists it must contain `default`. Without a catalog,
Zapp synthesizes `default` with every registered service and the app-wide
permissions, preserving the minimal configuration experience. Native Z may
select profiles when constructing a window:

```z
const diagnostics = try app.windows.create(WindowOptions({
  title: "Diagnostics",
  url: "/diagnostics",
  capabilities: Array<String>("diagnostics"),
}));
```

Web content cannot set `WindowOptions.capabilities`. A window created through
the frontend bridge inherits its caller's exact profile list, so it cannot
elevate itself by creating a child. Native dispatch checks the originating
window before entering a service and reports a structured
`PermissionDeniedError` such as `service:notes.create` when denied.

## Window navigation profiles

`security.navigation` is an immutable catalog of origins a trusted WebView may
navigate to and URL schemes the explicit shell manager may open:

```ts
security: {
  navigation: {
    default: { navigate: ["self"], openExternal: [] },
    documentation: {
      navigate: ["self", "https://docs.z-language.com"],
      openExternal: ["https:", "mailto:"],
    },
  },
},
```

`navigate` accepts `"self"` and canonical HTTP(S) origins, not URL paths.
`openExternal` accepts explicit schemes ending in `:`. When the catalog is
omitted, Zapp synthesizes a safe `default` profile containing only `"self"`;
when supplied, it must explicitly contain `default`.

Native application code selects one profile per window:

```z
const docs = try app.windows.create(WindowOptions({
  title: "Documentation",
  url: "/docs",
  navigation: "documentation",
}));
```

The selection is trusted policy: frontend `createWindow()` rejects a
`navigation` member and every frontend-created child inherits its creator's
profile. Unknown profile names fail window realization with a typed
`WindowError`. Every main-frame and subframe navigation passes through the
same native check.

Allowing an origin to navigate does not grant it the native bridge. The macOS
message entrypoint accepts bridge traffic only from the main frame at
`"self"`, and performs that check before message decoding. Remote pages are
therefore view-only, while same-origin subframes cannot invoke services or
window actions through WebKit's raw message handler. Trusted remote bridge
access is intentionally not inferred and has no configuration form yet.

After the profile check, native Z may narrow the result synchronously:

```z
const subscription = try window.events.navigationRequested.subscribe(
  move (in event: WindowNavigationRequestedEvent): void => {
    if (event.url == "https://docs.z-language.com/private") event.cancel();
  }
);
```

The TypeScript `WindowHandle` exposes the same request as a read-only
`WindowEvent.NAVIGATION_REQUESTED` payload containing `url`, `mainFrame`,
`allowedByProfile`, and `cancelled`. JavaScript cannot authorize or cancel it.
Navigation never interprets `openExternal` as an automatic handoff. A trusted
WebView must make a deliberate manager call:

```ts
import { Application } from "@zappdev/runtime/application";

await Application.current().shell.openExternal(
  "https://docs.z-language.com",
);
```

That frontend call requires app-wide `shell:open`, `shell:open` in the
originating window's selected capability profiles, and a matching scheme in
its navigation profile. Zapp derives the profile from the native window; the
request cannot substitute another profile. Policy denial and operating-system
failure reject with a focused `ShellError` carrying `operation` and `target`.

Trusted native Z is already inside the application boundary and uses the same
manager without a bridge or JSON hop:

```zs
import { Application } from "zapp";

const app = Application.current();
try app.shell.openExternal("https://docs.z-language.com");
```

Filesystem handoff uses explicit operations and the same compiled authority:

```ts
security: {
  permissions: ["shell:open", "shell:reveal", "shell:trash"],
  filesystem: { allow: ["$userData/**", "$resources"] },
  capabilities: {
    default: {
      permissions: ["shell:open", "shell:reveal", "shell:trash"],
    },
  },
}
```

```ts
const shell = Application.current().shell;
await shell.openPath("$userData/report.pdf");
await shell.reveal("$userData/report.pdf");
await shell.trash("$userData/old-report.pdf");
```

Direct file reads and writes add an operation permission while reusing the same
path authority:

```ts
security: {
  permissions: ["fs:read", "fs:write"],
  filesystem: { allow: ["$userData/**", "$resources"] },
  capabilities: {
    default: { permissions: ["fs:read", "fs:write"] },
  },
}
```

```ts
const files = Application.current().files;
const source = await files.readText("$resources/default-note.txt");
await files.writeText("$userData/note.txt", source);
```

Path-based manager calls require a configured filesystem root. A bare
`shell:*` permission never grants authority over every path, and `trash` moves
an item to the operating system Trash rather than permanently deleting it.

## Frontend origin and window URLs

`frontend.assets` names the built frontend directory embedded for production.
`frontend.devServer.port` selects the local Vite/Bun server used by `zapp dev`.
Neither value leaks into application-authored window routing:

```z
const window = try app.windows.create(WindowOptions({
  title: "Z Notes",
  url: "/notes",
}));
```

`WindowOptions.url` is always a logical application-relative path. Zapp owns
the transport resolution:

| Mode | Resolved application origin | Assets |
|---|---|---|
| Development | `http://localhost:<devServer.port>/` | Vite/Bun server and HMR |
| Packaged | `zapp://app/` on the macOS system WebView | Immutable bytes embedded in the executable |

An extensionless packaged route such as `/notes` falls back to
`/index.html`; a concrete missing asset remains a failure. Absolute URLs and
scheme-relative URLs are not accepted as `WindowOptions.url`. Remote content
will require a separate explicit API and never inherits the privileged native
bridge merely because a window navigated to it.

The custom WebKit scheme is not documented as an HTTP origin. In particular,
Zapp does not claim that HTTP-only response headers such as COOP/COEP make
`SharedArrayBuffer` portable through `zapp://`. Capability documentation will
record engine differences, and a native-backed shared-memory primitive remains
the portable fallback.

## Per-window trusted injection

`webview.inject` is a build-time catalog, not a global list applied to every
WebView. Profiles contain project-relative files that Zapp validates and
bundles into immutable native data:

```ts
export default defineConfig({
  application: { name: "Z Notes" },
  webview: {
    inject: {
      base: {
        styles: ["./src/injected/base.css"],
        documentStart: ["./src/injected/preload.ts"],
      },
      diagnostics: {
        documentEnd: ["./src/injected/diagnostics.ts"],
      },
    },
  },
});
```

Each dynamically created window selects the profiles it needs:

```z
const window = try app.windows.create(WindowOptions({
  title: "Diagnostics",
  url: "/diagnostics",
  inject: Array<String>("base", "diagnostics"),
}));
```

Selection order is preserved and repeated names are applied once. For each
selected profile Zapp installs styles, document-start scripts, and document-end
scripts in declaration order. The framework bridge is always the first
document-start script, so a trusted preload may use it immediately. Every
entry is main-frame-only and is reinstalled for subsequent navigations.

Profile names must begin with a letter and may contain letters, digits, dots,
underscores, and hyphens. Paths must remain inside the application root. CSS
entries use `.css`; script entries may use JavaScript or TypeScript extensions
and are bundled for the browser. Unknown names selected by `WindowOptions`
fail window startup with a typed `WindowError` (exported by
`@zappdev/runtime/window`) rather than becoming source.

This surface is for content that must run before the ordinary application
bundle or on every navigation. Normal application JavaScript and CSS belong in
the Vite frontend, where they retain HMR. Changing an injection profile file
currently requires restarting the native development host. Zapp does not
accept inline runtime source strings and does not implement these profiles with
`eval`.
