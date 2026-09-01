# ZJS worker-host proof

This private spike validates the engine boundary for the Z rewrite of Zapp
Workers without committing a public `Worker` API.

It proves that:

- Z owns the move-only lifetime of an opaque ZJS engine adapter;
- the engine runs on a dedicated `thread.spawn` worker and is joined;
- an ES module is evaluated through ZJS's stable C embedding ABI;
- JavaScript calls a checked `export c function` implemented in Z directly;
- the typed `i32` result returns through ZJS without WebView IPC or JSON; and
- lexical Z cleanup destroys the ZJS context after the worker completes.

Run from the Zapp repository root:

```sh
bun run spike:zjs-worker-host
```

By default the runner expects sibling `z-lang` and `zjs` repositories. Set
`ZAPP_Z_REPO` or `ZAPP_ZJS_REPO` to override either location. The runner uses
`zjs/build/libzjs.a`, building the minimal tier when it is absent. ZJS pins its
compatible Zen-C compiler revision; `ZAPP_ZC` and `ZAPP_ZC_ROOT` can point the
runner at that compiler and source tree. `ZAPP_ZJS_LIBRARY` can instead select
an already-built static archive.

This adapter is intentionally narrow. It keeps `ZjsContext`, `ZjsValue`, GC
roots, module evaluation, and engine error conversion out of Zapp's eventual
public worker model.
