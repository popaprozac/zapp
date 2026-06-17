# Nim App Entry — Design (Cycle 1)

**Goal (one sentence):** Make a real app's own native code — its `run_app` + service handlers, today written in Zen-C `app.zc` — run on the Nim build *in Nim*, proving "Nim runs a real app" end-to-end and unlocking the path to an all-Nim native side.

**Architecture:** Split `native/nim/*.nim` into an importable framework library + a thin entry; let an app supply `<app>/zapp/app.nim` (the idiomatic-Nim analog of `app.zc`); have the CLI's `buildNativeNim` compile that app entry as the root (falling back to today's hardcoded skeleton when absent); port kitchen-sink's `app.zc` → `app.nim` as the end-to-end proof. zc stays the default; nothing Zen-C is removed this cycle.

**Tech:** Nim (`nim c`), the existing C-ABI to the shared `.m`/engine `.c`, the generated `.zapp/*.nim` config modules, `cli/src/native.ts`.

---

## North star & why

- **End state (user direction, 2026-06-17):** the entire native side of a Zapp is Nim; Zen-C is retired. Not a permanent zc↔Nim bridge.
- **Rationale:** Zen-C is new/rough/single-maintainer (we've hit the JSON-parser overflow, dispatch-buffer truncation, pending buffer-truncation sweep, hand-maintained `compat.h` patches). Nim is mature/batteries-included, has excellent C interop, produces equal-or-smaller binaries with equal-or-better perf (measured here: Nim kitchen-sink ≈670 KB vs zc ≈710 KB; NimPerf alloc-free invoke), and is more approachable than Zen-C.
- **Today's gap:** the Nim build (`ZAPP_NATIVE_LANG=nim`) compiles only `native/nim/*.nim` + shared `.m`/`.c` and runs a hardcoded skeleton (`native/nim/zapp.nim`); it never compiles the app's `app.zc`, so the app's handlers/`run_app` don't run (kitchen-sink `greet → [object Object]`). The service **machinery is fully ported** (`service.nim` registry/invoke + `app.run()` flow mirror zc) — the *only* missing piece is the app's own code.

## Principles (carry through all Nim-app work)

1. **Idiomatic Nim where humans read/write it** (internal logic + the user-facing API); the C-ABI seam stays thin glue — we do NOT prettify `exportc` shims.
2. **TS stays the default home for app + business logic** — UI in the webview, heavy logic in headless workers (our differentiator). A native Nim service is the *exception*, for genuinely-native needs. "All-native-Nim" is about the framework, not about pushing app logic into Nim (protects the approachable-to-web-devs rationale).
3. **The app-authoring Nim API is ergonomic:** a plain `proc(args: JsonNode): string` + `registerService("greet", greet)`. No `exportc`/`gcsafe`/`ptr` ceremony surfaces to the app author.
4. **Power-user native extensibility is first-class:** an author may drop into raw Nim `importc` to wrap any native lib and expose it as a service — a deliberate Nim win over Zen-C.
5. **Additive + reversible:** zc + Zen-C apps remain the default; the Nim-app path is opt-in until parity is proven, then the default flips and Zen-C retires (separate later cycle).

## Design

### 1. Framework-as-library
Make `native/nim/*.nim` importable as a library (e.g. a `zappframework` umbrella module re-exporting `newApp`, `AppConfig`, `WindowOptions`/`newWindowOptions`, `createWindow`, `registerService`, `run`, the `JsonNode` service handler type, etc.). Today `zapp.nim` is the build root that hardcodes the skeleton boot; we separate "framework you import" from "the entry that boots it."

### 2. App-supplied Nim entry — `<app>/zapp/app.nim`
An app may provide a Nim entry, the idiomatic analog of today's `app.zc`:

```nim
import zappframework, std/json

proc greet(args: JsonNode): string = "Hello from Zapp!"

proc runApp*(): int =
  let a = newApp(AppConfig(name: "kitchen-sink",
                           applicationShouldTerminateAfterLastWindowClosed: true,
                           maxWorkers: 0))
  a.registerService("greet", greet)
  var opts = newWindowOptions("Kitchen Sink")
  opts.width = 1100; opts.height = 700
  opts.sidebarUrl = "#sidebar-pane"; opts.sidebarWidth = 240
  opts.inspectorUrl = "#inspector-pane"; opts.inspectorWidth = 300
  opts.inspectorCollapsed = true
  discard createWindow(opts)
  a.run()
```

Clean, no `exportc`. The generated `.zapp/*.nim` config getters (window JSON, bootstrap, headless, build-config, name) remain available; precedence: an explicit `app.nim` owns the boot, and may still read the config getters where useful (e.g. permissions/bootstrap that the CLI generates). Default rule of thumb: **app.nim is authoritative for what it sets.**

### 3. CLI: `buildNativeNim` compiles the app entry
`buildNativeNim` (`cli/src/native.ts`) compiles the app's `zapp/app.nim` as the Nim root (importing the framework via `--path`), instead of the hardcoded skeleton, **when the file exists**. The framework `.nim` modules, the generated `.zapp/*.nim`, the shared `.m`/engine `.c`, and the `zjson_provider` object all link as today.

### 4. Skeleton becomes the fallback
Retain the current hardcoded skeleton (now in the framework, behind a `zappDefaultMain()` or similar) as the **no-`app.nim` fallback** — so the migration is incremental and apps without a Nim entry (and `zapp init` before one is written) still boot.

### 5. Port kitchen-sink: `app.zc` → `app.nim`
Author `kitchen-sink/zapp/app.nim` mirroring `app.zc`'s `run_app` (window + sidebar/inspector opts) + `greet`. Verify the Nim build runs it: `greet` returns the real string (no more `[object Object]`), the native-chrome shell boots, all sections reachable. The **zc build keeps using `app.zc` unchanged** (kitchen-sink now carries both entries during the transition).

## Risks / gates

- **#1 risk — gate first (prove before porting):** framework-as-library + app-entry-compile. Refactor `zapp.nim`/`buildNativeNim` so a *trivial* hand-written `app.nim` root compiles + links the framework + `.m`/`.c`/engine + generated config modules and boots a window. Only after this gates green do we port kitchen-sink.
- **AppConfig parity:** `app.nim` constructs `AppConfig` (from `appconfig.nim`, NimB4) — confirm its fields cover what `app.zc`'s `AppConfig` sets (`name`, `applicationShouldTerminateAfterLastWindowClosed`, `webContentInspectable`, `maxWorkers`, `qjsStackSize`).
- **Build gates unaffected:** both builds stay green (zc default + nim); `#281` iOS-parity lint and tsc are untouched (no new `darwin_*` or runtime surface — this is build-orchestration + app-layer Nim).
- **`on_ready`/callbacks:** `app.zc` uses `win.on_ready(on_ready)`; confirm the Nim window API exposes the equivalent (or note the gap).

## Out of scope (parked, not this cycle)

- **nim→js for services / type-gen** (promising): a pure-logic Nim service could compile to JS for worker/webview contexts, and Nim signatures could source generated TS client types. But Nim's JS backend has no C-FFI/`importc`/threads, so it fits only the pure-compute subset, not native services. **Future spike**, not the native path.
- **Flipping the default to Nim / retiring Zen-C** — later cycle, once Nim-app parity is proven across apps.
- **Porting hello-world + full `app.zc`→`app.nim` authoring docs** — after kitchen-sink proves the path.
- **A higher-level app DSL** beyond raw idiomatic Nim — revisit only if the raw Nim app surface proves too heavy for the target audience (mitigated by principle 2: most logic stays TS).
- **`app.zc` → `app.nim` automated translation** — out; we hand-port the showcase, and real apps author `app.nim` directly.

## Verification (how we know Cycle 1 landed)

1. A trivial `app.nim` compiles + boots a window on the Nim build (risk gate).
2. `kitchen-sink/zapp/app.nim` exists; `ZAPP_NATIVE_LANG=nim bun run dev` (kitchen-sink) shows `greet → Hello from Zapp!` (real value, not `[object Object]`) and the full chrome shell.
3. `bun run dev` (zc, default) still runs kitchen-sink via `app.zc` unchanged.
4. Both builds report `[zapp] build complete`; tsc + `#281` lint unchanged.
