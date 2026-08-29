# Z Notes benchmark results

## 2026-08-29 foundation checkpoint

This is a **Zapp-only readiness baseline**, not yet a cross-framework verdict.
It proves that the shared product workload can be built and packaged through
the Z-native framework path before duplicating it across contemporaries.

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
```

Initial release artifact:

| Framework | Main executable | App bundle | Icon | Process startup* | Idle RSS |
|---|---:|---:|---:|---:|---:|
| Zapp (Z core) | 280,768 B | 913,408 B | 613,092 B | 99 ms | 23 MB |

`*` Three measured launches after the harness prime/warm-up behavior. The
historical harness records process appearance, not the new shared UI ready
marker, so this startup number is provisional. Product-grade first-paint and
workflow automation is part of the next harness slice.

The packaged app's first shared-UI load created the SQLite database and both
canonical seed rows. The bundle uses checked direct `sqlite3.h` interop and no
handwritten native shim.

The icon is reported separately because it is 67% of this initial bundle. All
framework implementations must eventually consume the same source icon; any
packaging-format difference remains visible rather than being subtracted.

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
