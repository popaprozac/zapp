# Z Notes product benchmark

This suite compares Zapp with other desktop-WebView frameworks using one small,
recognizable application rather than treating an empty window as the product.
The historical framework-floor measurements remain in [`../README.md`](../README.md).

## Workload contract

Every implementation must provide the same visible application and behavior:

- one native desktop window containing the shared static frontend in `shared/`;
- SQLite persistence with the schema `notes(id, title, body)`;
- the same two seeded notes on a fresh database;
- a typed service with `list` and `create` operations;
- create a note, refresh the list, remain idle, and shut down cleanly;
- embedded production assets and release/optimized native builds.

The browser-facing adapter is intentionally tiny and framework-specific. It must
implement this interface for the shared UI:

```ts
interface NotesAdapter {
  list(): Promise<Array<{ id: string; title: string; body: string }>>;
  create(input: { title: string; body: string }): Promise<{
    id: string;
    title: string;
    body: string;
  }>;
}
```

`shared/app.js` also exposes `globalThis.__zNotesBenchmark.run(iterations)`.
That deterministic workflow creates one note and reloads the full list per
iteration, allowing bridge/workflow timing without maintaining a separate
benchmark-only application.

## Measurement rules

Report each dimension separately:

| Dimension | Meaning |
|---|---|
| Main executable | Relevant native/framework executable bytes |
| App bundle | Uncompressed shipping bundle before first launch |
| Compressed artifact | Comparable distributable archive bytes |
| Cold launch | Process launch to the shared UI's ready marker |
| Idle memory | Resident/private memory after the same settle period |
| Workflow | Median duration of the shared create-and-refresh loop |
| Build | Clean and incremental release build wall time |

All measurements record machine, architecture, OS, framework versions, compiler
versions, run counts, and exact commands. A semantic mismatch is a failed run,
not an explanatory footnote.

## Current implementations

- `apps/zapp`: Z native core, checked direct `sqlite3.h` import, typed generated
  service bindings, and embedded assets.
- `apps/electron`: isolated preload bridge, Electron IPC, and Node's built-in
  SQLite implementation. Its package step stages the exact shared UI sources.
- `apps/tauri`: production Tauri 2.11 system WebView, typed Rust commands, and
  system SQLite through `rusqlite`.

Build and measure the first implementation with:

```sh
bun run bench:z-notes:reset
bun run bench:z-notes:zapp:build
bun run bench:z-notes:zapp:measure 15
bun run bench:z-notes:electron:build
bun run bench:z-notes:electron:measure 15
bun run bench:z-notes:tauri:build
bun run bench:z-notes:tauri:measure 15
bun run bench:z-notes:product zapp 7
bun run bench:z-notes:product electron 7
bun run bench:z-notes:product tauri 7
```

The product runner creates an isolated control file, resets that framework's
database, launches a fresh packaged process, waits for the shared UI ready
report, executes 100 create-and-full-refresh iterations, records the browser's
aggregate workflow duration, and terminates the complete app process tree. One
unreported prime run precedes the requested samples. Control and report files
are removed even when a measurement fails.

The rolling evidence and caveats live in [`RESULTS.md`](RESULTS.md).

The first Zapp checkpoint deliberately exposes a current generator boundary:
`Array<Note>` is not yet a supported generated service wire type. The native
service therefore returns a typed `NotesPage` containing exact JSON for the
list, and the Zapp adapter parses it. Other implementations must use the same
logical adapter contract; once Zapp gains collection codecs, this workaround is
removed and called out in the next result revision.
