# Z Notes benchmark results

## 2026-08-29 first peer checkpoint

This is the first cross-framework evidence checkpoint, not yet a complete
verdict. Zapp and Electron now package the same shared product workload;
Tauri, Wails, and Electrobun remain to be added before publishing a full table.

Machine:

- MacBook Pro, Apple M4 Pro, 24 GB
- arm64
- macOS 26.4 (25E5223i)
- Z 0.1.0-dev, compiler revision 2026-08-25.1, compiler API 2
- Apple Clang 17.0.0
- Bun 1.3.14

Commands:

```sh
bun run bench:z-notes:reset
bun run bench:z-notes:zapp:build
bun run bench:z-notes:zapp:measure 3
bun run bench:z-notes:electron:build
bun run bench:z-notes:electron:measure 3
```

Initial release artifact:

| Framework | Executable payload | App bundle | Icon | Process startup* | Idle RSS |
|---|---:|---:|---:|---:|---:|
| Zapp (Z core) | 280,768 B | 913,408 B | 613,092 B | 98 ms | 23 MB |
| Electron 41.2 | 178,890,304 B | 277,377,024 B | 272,259 B | 97 ms | 104 MB |

At this checkpoint Electron's bundle is about 304 times larger and its idle
process tree uses about 4.5 times the memory. Electron's executable payload is
the shipped Electron Framework binary rather than its tiny loader stub, using
the same historical harness rule.

`*` Three measured launches after the harness prime/warm-up behavior. The
historical harness records process appearance, not the new shared UI ready
marker, so this startup number is provisional. Product-grade first-paint and
workflow automation is part of the next harness slice.

Each packaged app's first shared-UI load created its isolated SQLite database
and the same two canonical seed rows. Zapp uses checked direct `sqlite3.h`
interop and no handwritten native shim; Electron uses Node's built-in SQLite
module behind an isolated preload bridge.

The icon is reported separately because it is 67% of Zapp's initial bundle.
Both implementations consume the same source artwork; their packaging-format
difference remains visible rather than being subtracted.

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
- Generated `Array<Struct>` service codecs remain an explicit limitation; the
  first adapter carries its list through a typed `NotesPage.notesJson` field.
