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
bun run bench:z-notes:product zapp 7
bun run bench:z-notes:product electron 7
```

Initial release artifact:

| Framework | Executable payload | App bundle | Icon | Process startup* | Idle RSS |
|---|---:|---:|---:|---:|---:|
| Zapp (Z core) | 281,520 B | 913,408 B | 613,092 B | 99 ms | 23 MB |
| Electron 41.2 | 178,890,304 B | 277,377,024 B | 272,259 B | 102 ms | 111 MB |

At this checkpoint Electron's bundle is about 304 times larger and its idle
process tree uses about 4.8 times the memory. Electron's executable payload is
the shipped Electron Framework binary rather than its tiny loader stub, using
the same historical harness rule.

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
| Zapp (Z core) | 344.442 ms | 154.0 ms |
| Electron 41.2 | 377.077 ms | 101.8 ms |

Zapp reaches the actual shared ready point about 33 ms earlier in this sample.
Electron completes the current workflow about 52 ms earlier. The latter is a
useful exposed limitation, not a reason to distort the peer adapter: Zapp's
generated service layer cannot yet carry `Array<Note>`, so the Z service first
encodes the list into a JSON string inside `NotesPage`, the outer generated
bridge serializes that page, and the frontend parses the inner JSON again.
Electron transfers the array directly through its ordinary structured IPC.
The benchmark should be rerun unchanged when generated collection codecs land.

The exact seven-run samples were:

```text
Zapp ready:    352.099, 345.405, 340.210, 331.451, 337.737, 344.442, 348.145 ms
Zapp workflow: 159, 169, 165, 151, 154, 149, 143 ms
Electron ready:    412.354, 366.976, 375.411, 388.243, 371.683, 377.077, 389.399 ms
Electron workflow: 107.5, 90.2, 101.8, 116.3, 107.8, 84.4, 99.2 ms
```

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
