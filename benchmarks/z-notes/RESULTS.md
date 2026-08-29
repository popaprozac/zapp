# Z Notes benchmark results

## 2026-08-29 first peer checkpoint

This is the first cross-framework evidence checkpoint, not yet a complete
verdict. Zapp, Electron, Tauri, and Wails now package the same shared product
workload; Electrobun remains to be added before publishing a full table.

Machine:

- MacBook Pro, Apple M4 Pro, 24 GB
- arm64
- macOS 26.4 (25E5223i)
- Z 0.1.0-dev, compiler revision 2026-08-25.1, compiler API 2
- Apple Clang 17.0.0
- Bun 1.3.14
- Rust/Cargo 1.97.1
- Go 1.25.0
- Wails 3.0.0-beta.16 and `@wailsio/runtime` 3.0.0-beta.16

Commands:

```sh
bun run bench:z-notes:reset
bun run bench:z-notes:zapp:build
bun run bench:z-notes:zapp:measure 3
bun run bench:z-notes:electron:build
bun run bench:z-notes:electron:measure 3
bun run bench:z-notes:tauri:build
bun run bench:z-notes:tauri:measure 3
bun run bench:z-notes:wails:build
bun run bench:z-notes:wails:measure 3
bun run bench:z-notes:product zapp 7
bun run bench:z-notes:product electron 7
bun run bench:z-notes:product tauri 7
bun run bench:z-notes:product wails 7
```

Initial release artifact:

| Framework | Executable payload | App bundle | Icon | Process startup* | Idle RSS |
|---|---:|---:|---:|---:|---:|
| Zapp (Z core) | 281,536 B | 913,408 B | 613,092 B | 104 ms | 24 MB |
| Electron 41.2 | 178,890,304 B | 277,377,024 B | 272,259 B | 102 ms | 111 MB |
| Tauri 2.11 | 10,839,632 B | 11,476,992 B | 627,078 B | 105 ms | 26 MB |
| Wails 3.0.0-beta.16 | 8,750,208 B | 9,060,352 B | 65,857 B | 118 ms | 31 MB |

At this checkpoint Electron's bundle is about 304 times larger and its idle
process tree uses about 4.6 times the memory. Electron's executable payload is
the shipped Electron Framework binary rather than its tiny loader stub, using
the same historical harness rule.

Tauri's system-WebView bundle is about 12.6 times larger than Zapp's while its
idle memory is close: 26 MB versus 24 MB in these samples.

Wails' system-WebView bundle is about 9.9 times larger than Zapp's and its idle
process uses 31 MB versus Zapp's 24 MB. Its executable is smaller than Tauri's
in this build, while both remain substantially larger than Zapp's direct native
core.

`*` Three measured launches after the harness prime/warm-up behavior. The
historical harness records process appearance, not the new shared UI ready
marker, so this coarse number is retained only for continuity with the older
framework-floor suite. The product-aware timing below is the primary result.

### Shared product timing

The product runner uses one unreported prime plus seven fresh-process samples.
Every sample removes that framework's database, waits for the same shared UI
ready report, then performs 100 sequential create-and-full-list-refresh
iterations through the public frontend adapter.

| Framework | Launch to shared UI ready | 100 create + refresh iterations |
|---|---:|---:|
| Zapp (Z core) | 341.557 ms | 153.0 ms |
| Electron 41.2 | 377.077 ms | 101.8 ms |
| Tauri 2.11 | 391.093 ms | 164.0 ms |
| Wails 3.0.0-beta.16 | 379.655 ms | 245.0 ms |

Zapp reaches the actual shared ready point about 36 ms before Electron and
about 50 ms before Tauri in this sample. It reaches ready about 38 ms before
Wails. Electron completes the current workflow about 51 ms earlier; Tauri takes
about 11 ms longer than Zapp, and Wails takes about 92 ms longer.

This rerun follows the addition of recursive generated `Array<T>` service
codecs and removal of Z Notes' nested-JSON workaround. The Z service now
returns `NotesPage { notes: Array<Note>, count }`, generated TypeScript exposes
`notes: Array<Note>`, and the frontend consumes it directly. The workflow
median moved from 154 ms to 153 ms, so the prior nested-JSON explanation was
not the material source of Electron's lead at this workload size. That gap now
requires bridge-level profiling rather than another inferred explanation.

The exact seven-run samples were:

```text
Zapp ready:    371.407, 341.491, 341.557, 340.127, 340.663, 344.664, 431.875 ms
Zapp workflow: 165, 162, 144, 136, 153, 139, 187 ms
Electron ready:    412.354, 366.976, 375.411, 388.243, 371.683, 377.077, 389.399 ms
Electron workflow: 107.5, 90.2, 101.8, 116.3, 107.8, 84.4, 99.2 ms
Tauri ready:    406.936, 395.544, 378.522, 383.382, 381.615, 392.119, 391.093 ms
Tauri workflow: 187, 159, 162, 183, 164, 154, 167 ms
Wails ready:    372.358, 379.655, 369.203, 382.548, 399.678, 363.463, 397.758 ms
Wails workflow: 256, 226, 212, 246, 245, 231, 278 ms
```

Each packaged app's first shared-UI load created its isolated SQLite database
and the same two canonical seed rows. Zapp uses checked direct `sqlite3.h`
interop and no handwritten native shim; Electron uses Node's built-in SQLite
module behind an isolated preload bridge; Tauri uses system SQLite behind
typed Rust commands; Wails uses Apple SDK SQLite behind generated TypeScript
bindings and typed Go service methods. `otool` confirms the Wails executable
links `/usr/lib/libsqlite3.dylib`, rather than the Homebrew library selected by
`go-sqlite3`'s default Darwin-arm64 external-library path.

The icon is reported separately because it is 67% of Zapp's initial bundle.
All implementations consume the same source artwork; their packaging-format
differences remain visible rather than being subtracted.

### Composition findings

Building this first real workload closed or exposed these general seams:

- Z-native `zapp package` now accepts the optimized Z core.
- Zapp now merges application-owned `z.json` native include/link requirements
  into its generated build manifest.
- Generated Z services now encode exact small integer fields through nominal
  `JsonNumber` values.
- The fixed-point compiler now preserves status-returning C handle cleanup,
  borrowed C-string inputs, explicit null-only parameters, safe `i32` to `i64`
  widening, borrowed character-pointer casts, and `String.from(cstring)`.
- Generated Z service codecs now carry recursive `Array<T>` shapes, including
  arrays nested in exported structs. Native Z dispatch, generated TypeScript,
  and the injected WebView runtime share the compiler-derived wire shape.
- Removing the handwritten nested-JSON list path did not materially change the
  100-operation median. The remaining Electron workflow lead is now a concrete
  bridge-profiling target rather than attributed to collection serialization.
- The Wails peer uses the current 3.0.0-beta.16 release, current generated
  bindings, the shared frontend without product-specific benchmark shortcuts,
  and the same database lifecycle. It establishes a fourth end-to-end product
  point without relying on the repository's older Wails alpha floor fixture.
