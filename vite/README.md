# @zappdev/vite

Vite plugin for [Zapp](https://github.com/zappdev/zapp). Resolves generated Z
service bindings, bundles workers, routes headless workers from
`zapp.config.ts`, and serves worker scripts in dev.

## Install

`zapp init` scaffolds this automatically. For manual setup:

```bash
bun add -D @zappdev/vite
```

## Usage

```ts
// vite.config.ts
import { defineConfig } from "vite";
import { zapp } from "@zappdev/vite";

export default defineConfig({
  plugins: [zapp()],
});
```

The Zapp CLI evaluates `zapp.config.ts` once, validates it, and writes a
normalized `.zapp/config.resolved.json` snapshot before Vite starts. The plugin
reads worker configuration from that snapshot; `vite.config.ts` never imports
or re-evaluates executable Zapp configuration.

## What the plugin does

### Generated Z services

Resolves the application-owned `zapp:services` module to the typed bindings
generated from Z compiler metadata before Vite starts. The same alias is
forwarded into nested worker builds, so WebViews and workers use one import:

```ts
import { notes, NoteCreationError } from "zapp:services";
```

### Webview-spawned worker discovery

Scans your source files for `new Worker("./path")` and
`new SharedWorker("./path")` patterns at build time. For each unique worker
script:

1. Bundles it as a separate entry (via Vite's build API) to
   `dist/_workers/<name>.mjs`.
2. Rewrites the source specifier to the bundled URL so the runtime can
   load it via the WebView's standard `new Worker("/_workers/...")` call.

### Headless worker bundling

For each entry in `zapp.config.ts → workers.headless: { id: "path" }`, bundles the
source to `dist/_workers/_headless_<id>.mjs`. Native code loads these at
app boot via the generated `.zapp/zapp_headless_workers.zc`.

### Dev middleware

In `zapp dev`, the plugin installs a middleware on Vite's dev server that
serves `/_workers/*` from the live-bundled `.zapp/workers/` directory, so
the WebView and native worker loader can fetch worker scripts over HTTP
during development.

### Alias forwarding

Picks up `resolve.alias` from your Vite config and applies the same
aliases when bundling workers, so path mappings like `@/*` work inside
worker code.

## Options

```ts
interface ZappOptions {
  /**
   * Headless workers: map of worker ID → source path (relative to project root).
   * Optional integration override. Ordinary Zapp apps use the CLI snapshot.
   */
  headless?: Record<string, string>;
}
```

## Reference

Full framework overview, runtime API, and worker semantics:
see [`llms.txt`](../llms.txt) at the repo root.
