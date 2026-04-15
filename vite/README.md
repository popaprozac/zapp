# @zappdev/vite

Vite plugin for [Zapp](https://github.com/zappdev/zapp). Bundles workers,
routes headless workers from `zapp.config.ts`, serves worker scripts in
dev.

## Install

`zapp init` scaffolds this automatically. For manual setup:

```bash
bun add -D @zappdev/vite
```

## Usage

```ts
// vite.config.ts
import { defineConfig } from "vite";
import { zappWorkers } from "@zappdev/vite";
import zappConfig from "./zapp.config";

export default defineConfig({
  plugins: [
    zappWorkers({ headless: zappConfig.headless }),
    // ...your other plugins
  ],
});
```

Pass `headless` directly from your `zapp.config.ts` so the plugin stays
in lockstep with the rest of the build.

## What the plugin does

### Webview-spawned worker discovery

Scans your source files for `new Worker("./path")` and
`new SharedWorker("./path")` patterns at build time. For each unique worker
script:

1. Bundles it as a separate entry (via Vite's build API) to
   `dist/_workers/<name>.mjs`.
2. Rewrites the source specifier to the bundled URL so the runtime can
   load it via the WebView's standard `new Worker("/_workers/...")` call.

### Headless worker bundling

For each entry in `zapp.config.ts → headless: { id: "path" }`, bundles the
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
interface ZappWorkersOptions {
  /**
   * Headless workers: map of worker ID → source path (relative to project root).
   * Usually passed straight from zapp.config.ts's `headless` field.
   */
  headless?: Record<string, string>;
}
```

## Reference

Full framework overview, runtime API, and worker semantics:
see [`llms.txt`](../llms.txt) at the repo root.
