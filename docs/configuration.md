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

  workers: {
    capabilities: ["fetch", "websocket"],
    headless: {
      sync: {
        script: "src/workers/sync.ts",
        engine: "zjs",
        restart: { maxRetries: 3, withinMs: 60_000 },
      },
    },
  },

  security: {
    permissions: ["clipboard:read", "notifications"],
    filesystem: {
      allow: ["$userData/**"],
      persistDialogGrants: true,
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
becomes an authorization surface. `Application()` receives both generated
values by default, and application source cannot replace policy with data from
a WebView.

Runtime behavior does not belong in configuration. Services, windows, menus,
lifecycle hooks, and mutable state remain ordinary Z source.

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
