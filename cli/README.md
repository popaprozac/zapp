# @zappdev/cli

Build tool for [Zapp](https://github.com/zappdev/zapp) desktop apps.
Scaffolds projects, runs the dev loop, and produces release binaries.

## Install

Don't install globally. Scaffold with `bunx`, then let the project's local
copy drive subsequent commands:

```bash
bunx @zappdev/cli init my-app
cd my-app
bun install
bun run dev
```

`bunx` pulls the CLI on the fly for the `init`; afterwards `bun run <script>`
resolves to the local `node_modules/.bin/zapp` pinned in `package.json`.
This guarantees your project keeps working even as the CLI evolves.

## Requirements

- **Bun** ≥ 1.3
- **Zen-C compiler (`zc`)** — https://github.com/zenc-lang/zenc
- **Xcode Command Line Tools** (macOS) — for `codesign`, `iconutil`
- **cmake** — only required on first build with `ZAPP_WORKER_ENGINE_TXIKI`,
  downloads and builds a patched txiki.js into `~/.zapp/vendor/`

## Commands

### `zapp init <name> [-t template]`

Scaffolds a new Zapp project. Defaults to `vanilla-ts`; other
`create-vite` templates (`svelte-ts`, `react-ts`, `vue-ts`, `solid-ts`, etc.)
work too.

```bash
bunx @zappdev/cli init my-app              # vanilla-ts
bunx @zappdev/cli init my-app -t svelte-ts
```

Produces a ready-to-run project with `@zappdev/cli`, `@zappdev/runtime`,
`@zappdev/vite` as dependencies pinned to `^0.6.0-alpha.0`. Vite config is
auto-wired with the `zappWorkers()` plugin forwarding
`zapp.config.ts → headless` to the worker bundler.

### `zapp dev`

Compiles the native binary, starts the Vite dev server on port 5173 (or the
configured `devPort`), launches the packaged `.app` with a live-reloading
webview. Workers re-bundle on source change.

Watches `zapp/**` for Zen-C changes and recompiles. Kill with Ctrl-C.

### `zapp build`

Produces a production binary in `bin/`. Runs `vite build` first, embeds the
output as brotli-compressed assets inside the binary. No dependencies
beyond the OS's WebView — a single file you can ship.

### `zapp package`

Creates a macOS `.app` bundle in `release/` with:
- The binary at `Contents/MacOS/<name>`
- Icon from `zapp.config.ts → macos.icon` (converted to multi-resolution
  `.icns` / asset catalog; macOS Sonoma+ picks up "liquid glass" rendering
  automatically for PNG icons)
- `Info.plist` derived from `identifier`, `version`, `macos.category`
- Adhoc signing (or your `macos.signingIdentity` if provided)

### `zapp generate`

Scans `zapp/**/*.zc` for `app.service.add("name", fn)` calls, emits
auto-generated TypeScript bindings under `src/generated/`. Run this after
adding or renaming services to get autocomplete and type-checked invoke
calls.

## Flags

- `--verbose` / `-v` — stream full `zc` + `clang` output. By default only
  error lines are shown (framework + stdlib generate ~200 warnings that
  are noise).
- `-r <path>` — operate on a project at a different directory.

## Project structure

`zapp init` scaffolds:

```
my-app/
├── package.json, tsconfig.json, vite.config.ts, index.html
├── src/                   # your TS / UI code
├── zapp/                  # your Zen-C (native) code — app.zc, build.zc
├── zapp.config.ts         # app identity, headless workers, macOS opts
├── build/                 # platform-specific build inputs
│   ├── README.md
│   └── macos/             # drop icon.{icon,icns,iconset,png} or Info.plist.extra
└── .zapp/                 # CLI-generated, gitignored
```

The `build/` directory is where you put **build inputs you control**:

- `build/macos/icon.{icon,icns,iconset,png}` — app icon (any of these
  formats). CLI auto-detects.
- `build/macos/Info.plist.extra` — optional partial Info.plist; key/value
  pairs are merged into the generated plist at package time.
- `build/macos/app.entitlements` — optional code-signing entitlements
  file; passed to `codesign --entitlements` during `zapp dev` and
  `zapp package`. Override the path via `macos.entitlementsFile` or
  add typed entries inline via `macos.entitlements`.

Any `.m` (macOS) or `.c` (Windows) files dropped anywhere under `zapp/`
are auto-compiled and linked into the binary — useful for system APIs
that are easier to call from ObjC than from Zen-C (Keychain,
AVFoundation, NSWorkspace). No config needed. See
[`docs/zen-c-services.md`](../docs/zen-c-services.md) → "Services in
ObjC or C" for the bridging pattern.

For inline `Info.plist` customization (typed, autocomplete-friendly), use
`zapp.config.ts → macos.copyright`, `macos.usageDescriptions`,
`macos.plistExtras`. Entitlements live alongside in
`macos.entitlements` (typed map) or `macos.entitlementsFile` (path to
`.entitlements`). See [`llms.txt`](../llms.txt) → "build/" and
"Entitlements" for priority rules and the ad-hoc signing caveat.

## txiki.js on first build

If your `zapp/build.zc` defines `ZAPP_WORKER_ENGINE_TXIKI`, the CLI
downloads txiki.js on first build to `~/.zapp/vendor/txiki.js` and builds
it via cmake (~60 s one-time, then cached). The download is pinned to a
known-good commit; a local patch file at
`@zappdev/cli/patches/txiki-cookie-jar-path.patch` is applied to add a
small embedder helper that hasn't been upstreamed yet.

## Troubleshooting

**"port 5173 is already in use"** — a previous `zapp dev` died with a
compile error before killing Vite. Kill the process with `kill <pid>` (the
CLI prints the PID); this is handled automatically in 0.6.0-alpha.5+, but
older versions may still leak.

**"Cannot find v2 native framework"** — the CLI can't locate the bundled
`native/` directory. Usually means the npm install was interrupted. Run
`bun install` again.

**"TJS_SetCookieJarPath" undefined symbol** — the downloaded txiki.js
cache is stale (predates the pinned commit). Clear it:
`rm -rf ~/.zapp/vendor/txiki.js` and rebuild.

## Reference

Full framework API, config shapes, and patterns: see [`llms.txt`](../llms.txt)
at the repo root. Longer-form guides in [`docs/`](../docs/).
