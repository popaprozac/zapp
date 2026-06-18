# Nim Prod macOS Build (roadmap gap #1) — Design

**Status:** DESIGNED — 2026-06-18. Make the Nim build path produce a
**distributable** macOS binary (embedded assets, prod build-config) so
`zapp package` yields a self-contained `.app`. Today the Nim build is dev-shaped
(empty asset table → filesystem fallback, hardcoded `isDev:true`/`embedAssets:false`/
`devTools:1`, ignores `optimize`). First gap on the
`docs/nim-migration-roadmap.md` path to replacing Zen-C.

## Key finding

"Prod build" for Nim is **not** about Nim optimization — the Nim compile is
already `-d:release --opt:size` regardless of mode (`native.ts:~1248`). The gap is
three things: (1) embed the web assets, (2) thread the prod build-config flags
through `buildNativeNim`, (3) make `createProductionBundle`'s embedded-detection
robust.

The asset pipeline has three separable layers; only the **embed** layer changes:
- **Compress** `dist/`→`.br`: already in the TS CLI (`assets.ts`, Bun `zlib`
  brotli, q11). Language-agnostic; unchanged.
- **Embed** `.br` into the binary: the zc path uses `embed`/`raw{}`
  (`zapp_assets.zc`); Nim today ships an empty stub. **This is what we build.**
- **Decompress** at runtime (serve `zapp://`): shared `webview.m` via Apple
  `libcompression` (`COMPRESSION_BROTLI`), already linked in the Nim build
  (`zapp.nim:208 -lcompression`). Unchanged on macOS. (Windows has no
  libcompression → tracked separately, task #516, for roadmap gap #6.)

## Decision

### 1. Embed via Nim stdlib `staticRead` (new CLI emitter)

A new CLI emitter generates `.zapp/zapp_assets.nim` that uses Nim's stdlib
`staticRead` (the idiomatic compile-time embed — bytes baked into rodata, **not**
rolling our own) to bake the existing `.zapp/assets/*.br` payloads and build the
`{.exportc.}` table the native scheme handler reads. Drop `zapp.nim`'s empty stub
so there's no duplicate symbol. This keeps assets **zc-free** (a down-payment on
gap #2 de-zc — the explicit "lean on Nim, leave zc" direction).

The generated module must match the exact C-ABI the `.m` consumers expect
(`native/platform/darwin/webview.m:186-202`; iOS twin) — the struct
`ZappEmbeddedAsset{ path:cstring, data:ptr uint8, len:cint, uncompressed_len:cint,
is_brotli:cint }` and the symbols `zapp_embedded_assets` (array) +
`zapp_embedded_assets_count` (cint). Shape:
```nim
const a0 = staticRead("assets/index.html.br")   # path relative to .zapp/
# ...one per asset...
var zapp_embedded_assets* {.exportc.}: array[N, ZappEmbeddedAsset] = [
  ZappEmbeddedAsset(path: "index.html",
    data: cast[ptr uint8](unsafeAddr a0[0]), len: a0.len.cint,
    uncompressed_len: <origSize>.cint, is_brotli: 1),
  # ...
]
var zapp_embedded_assets_count* {.exportc.}: cint = N
```
(The `ZappEmbeddedAsset` type stays defined once — move it from the stub in
`zapp.nim` into the generated module, or a shared spot; the generated module owns
the populated arrays.) The emitter reuses the `.br` payloads + uncompressed sizes
that the existing `assets.ts` flow already computes (so brotli compression is NOT
re-implemented — only the embed codegen is new). Empty-set fallback (no assets /
dev) keeps a `count = 0` table so symbols still link.

**`buildNativeNim`** compiles it via the existing `--path:${zappDir}` (it already
adds `.zapp` to the Nim path); `import zapp_assets` from `zapp.nim` in embed mode.
Brotli decode already links (`-lcompression`).

### 2. Thread prod flags through `buildNativeNim`

`buildNativeNim` gains an `optimize`/`embed` signal (the zc path's `compileNative`
already computes `optimize: true` for `zapp build`/`package`, `false` for `zapp
dev` — pass `opts.optimize` to `buildNativeNim`, which it currently drops at
`native.ts:~1268`). Then set `renderBuildConfigNim`:

| flag | dev (`zapp dev`) | prod (`zapp build`/`package`) |
|---|---|---|
| `embedAssets` | false (filesystem) | **true** (embedded table) |
| `devTools` | 1 | **0** |
| `isDev` | true | **false** |
| `assetRoot` | resolved `dist/` | `""` (served from the embedded table) |
| emit `zapp_assets.nim` | no (stub `count=0`) | **yes** (real table) |

`renderBuildConfigNim` already accepts these as params (`build-config.ts:197-227`);
only `buildNativeNim`'s call site forces dev values today.

**Also thread real CSP + custom protocols** into `renderBuildConfigNim` (it
currently hardcodes `csp=""` / `custom_protocols_json="[]"` — `build-config.ts:217,
220`), mirroring zc's `generateBuildConfig`, so a prod app that sets a CSP or
custom protocols gets them. (In-scope: a distributable build that silently drops
configured CSP/protocols is wrong. If the wiring proves larger than expected,
split to a follow-up — but attempt it here.)

### 3. Robust embedded-detection in `createProductionBundle`

Today `package.ts:50` decides embedded-vs-filesystem by the **presence of the
zc-only `.zapp/zapp_assets.zc`** — language-coupled, and a latent bug (the zc dev
stub also writes that file → a dev-stub package wrongly takes the embedded branch
and ships no assets). Replace with a **language-agnostic marker**: the embed step
(zc prod `generateAssetManifest` AND the new Nim emitter) writes
`.zapp/assets-embedded` iff assets were actually embedded; dev/stub paths don't.
`package.ts` checks the marker:
- marker present → **embedded branch** (assets in the binary; skip copying `dist/`).
- marker absent → **filesystem branch** (copy `dist/` into `Resources/`).

This makes Nim-prod package correctly (embedded, no dist copy), Nim-dev/zc-dev
package correctly (filesystem), and fixes the pre-existing zc dev-stub bug — one
small shared change.

## Components

- `cli/src/assets.ts` (or a sibling) — new `generateAssetManifestNim(root, assetDir)`
  emitting `.zapp/zapp_assets.nim` (reuses the `.br` payloads + sizes); + write the
  `.zapp/assets-embedded` marker; have the zc `generateAssetManifest` write the
  same marker.
- `native/nim/zapp.nim` — remove the empty stub table; `import zapp_assets` (the
  generated module) in embed builds; keep a `count=0` fallback path for dev/no-assets.
- `cli/src/native.ts` `buildNativeNim` — accept `optimize`; emit the Nim asset
  module + set `renderBuildConfigNim` flags by mode; pass CSP/protocols.
- `cli/src/build-config.ts` `renderBuildConfigNim` — thread CSP + custom protocols
  (stop hardcoding).
- `cli/src/package.ts` — marker-based embedded-detection (replaces the
  `zapp_assets.zc` presence check).

## Testing

- **bun:test** for the Nim asset emitter — pure codegen: given a fake asset list,
  asserts the generated `.nim` has the `{.exportc.}` `zapp_embedded_assets` array
  (right struct fields, paths, `is_brotli:1`, `count`) + `staticRead` calls.
- **Embedded build**: `cd kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build`
  (prod) → `[zapp] build complete:`; assert `.zapp/zapp_assets.nim` exists with a
  non-empty table + the `assets-embedded` marker; the generated build-config has
  `embedAssets=1`/`devTools=0`/`isDev=false`.
- **Self-contained gate (human/automated)**: run the prod nim binary with `dist/`
  moved/renamed → the app still loads its UI from the embedded table (proves
  detached/distributable). Dev build (`bun run dev`) still serves from filesystem.
- **Package**: `ZAPP_NATIVE_LANG=nim bun run package` (macOS) → `.app` that runs
  with NO sibling `dist/` (embedded branch taken, no resource copy). zc package
  unaffected (marker still written by `generateAssetManifest`).
- Full gate: nim + zc builds, tsc, `cd cli && bun test src`, nim unit tests.

## Out of scope (later roadmap gaps)
- De-zc-ing the JsonValue provider + zjs build (gap #2) — assets become zc-free
  here, but `buildNativeNim` still `zc transpile`s those two.
- iOS / Windows prod builds (gaps #5/#6); Windows brotli runtime decode = task #516.
- Bare-* engines in the Nim build (gap #4).

## Parity note
The Nim embed uses stdlib `staticRead` rather than zc's `embed`/`raw{}` — a
deliberate Nim-native mechanism, not a 1:1 zc port (zc has no `staticRead`
analog). The runtime contract (`zapp_embedded_assets[]` + libcompression decode)
is identical, so `webview.m` is unchanged and shared.
