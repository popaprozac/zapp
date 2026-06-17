# Nim WindowManager Port (runtime windows) — Design

**Date:** 2026-06-16
**Branch:** `feat/nim-native` (the next Nim breadth cycle after B7)
**Status:** Approved design → ready for implementation plan

## Purpose

Port the **runtime WindowManager** to the Nim native layer so JS `Window.create(...)` and `Window.createPopover(...)` work on the Nim build (`ZAPP_NATIVE_LANG=nim`). Today these no-op on Nim (the router's `__window:create`/`__popover:create` paths aren't ported), which is why new windows can't be opened. Closes the B8-deferred `popover:create`.

## Scope decision (what's IN, what's deferred)

**Architecture finding:** the Nim build does **not** run the user's `app.zc`. Its entry is hardcoded in `native/nim/zapp.nim` (lines 234-244): it constructs one plain 900×650 window (no chrome) via `createWindow` and loads the app's web bundle. Runtime `Window.create` from JS is a separate path — the router's `__window:create` — which on Nim currently no-ops.

- **IN (this cycle): runtime WindowManager** — the JS-driven `Window.create` / `popover:create` / slot allocation path. After this, on the Nim build: new windows, sheets, popovers, and the kitchen-sink **Multi-window** section all work; a JS-created window *with* `sidebar`/`inspector` opts mounts native chrome (the port pre-allocates the transport slots), so native chrome is demonstrable on Nim via a JS-created window.
- **DEFERRED: initial-window-as-app-shell on Nim** — making the Nim build's *first* window be the app's configured window (with chrome) so the kitchen-sink shell appears on the initial Nim window. This requires the Nim build to consume the app's initial-window config, which lives in `app.zc` (not run on Nim) and is not in `zapp.config.ts` — a new config→codegen→`zapp.nim` path. That is really the "Nim build runs the real app" milestone (on the road to the single-`main` merge) and has its own prerequisites; deferred to its own cycle. Tracked as a follow-on.

## Background facts (verified against source)

- **zc reference:** `WindowManager` (`native/window/window.zc:815-919`): `next_id: int` + a `handles: Map<u64>` registry; `create(opts)` pre-assigns `numericIdPreAlloc` then (only when the url is set) `sidebarNumericId` / `inspectorNumericId` from the **same monotonic** `next_id` space, calls `window_create`, registers the handle, and attaches as a sheet when `asSheetOfId >= 0`; `alloc_slot()` draws one id; `get(id)`/`close(id)` use the handles map.
- **`__window:create`** (`router.zc:186-208`): `window_opts_apply_json(&opts, args)` → `app.window.create(&opts)` → `window_opts_free` → `dispatch_invoke_response(...)`.
- **`__popover:create`** (`router.zc:215-275`): parse `windowId` (→ numeric via `darwin_window_numeric_id_for_string`), `url`, `behavior` (default `"transient"`), `width` (320), `height` (400); if `url != ""`: `slot = alloc_slot()`, `host = darwin_window_get_by_numeric_id(target)`, then `darwin_popover_create(host, "pop-<slot>", url, w, h, behavior, target, slot)`; respond `{"popoverId":"pop-<slot>"}`.
- **Nim today:** `native/nim/window.nim` has the `WindowOptions` ref object + all `wopts_*` accessors + a **partial** `createWindow*` (allocates `gNextWindowId`, sets `numericIdPrealloc`, `darwin_window_create` with GC pin/unpin, `darwin_window_register_numeric_id`). It does **not** pre-allocate sidebar/inspector slots, has no `alloc_slot`, no asSheetOf, and no registry. `router.nim` has no `__window:create`/`__popover:create` (the t:4 `popover:*` arm even has `else: discard # popover:create deferred`). Window *ops* (setTitle/close/attachModal/etc.) already work on Nim via the `.m` registry (`darwin_window_get_by_numeric_id`, B5b).
- **No Nim handle map needed:** the `.m` registry (`darwin_window_register_numeric_id` / `darwin_window_get_by_numeric_id`) is the single source of truth the Nim build already uses for window lookups. So the Nim WindowManager does not replicate the zc's `handles: Map` — `get`/`close`/asSheetOf-parent-lookup delegate to the `.m` registry. This is a deliberate simplification over the zc.
- **Thread discipline:** window creation runs on the **main thread** (router + boot). Idiomatic Nim — no gcsafe/POD constraints (unlike the worker registry). Reuses the GC pin/unpin pattern already in `createWindow` for the `darwin_window_create` call.
- **`darwin_popover_create`** is already compiled into the Nim build (popover.m, B8a); `darwin_window_get_by_numeric_id` + `darwin_window_numeric_id_for_string` + the attach-modal path are all already imported/used by the Nim router (B5b).

## Architecture / Components

### 1. WindowOptions runtime fields (`native/nim/window.nim`)
The skeleton ref object covers basic fields. Add what a JS `Window.create` can pass that it lacks — chiefly `asSheetOfId: int32` (default -1), plus `sheetPresentation: int32` / `sheetDetents: int32` / `sheetGrabber: bool` for iOS-parity data flow (macOS no-ops). `asSheetOfId` is Nim-side only (consumed by `wmCreate`); it is NOT exposed as a `wopts_*` accessor because `window.m` doesn't read it (the zc WindowManager handles the attach after create). If `window_opts_apply_json` sets any other field the Nim ref still lacks (audit `window.zc:336-630` during the plan), add it + its `wopts_*` accessor.

### 2. `wmCreate` + `wmAllocSlot` (`native/nim/window.nim`)
Extend the existing `createWindow` into `wmCreate(o: WindowOptions): tuple[id: int32, handle: pointer]`:
- allocate `id = gNextWindowId; inc gNextWindowId`; set `o.numericIdPrealloc = id`.
- if `o.sidebarUrl != ""`: `o.sidebarNumericId = gNextWindowId; inc gNextWindowId`.
- if `o.inspectorUrl != ""`: `o.inspectorNumericId = gNextWindowId; inc gNextWindowId`.
- if `o.asSheetOfId >= 0`: `o.visible = false`.
- `GC_ref(o)` → `darwin_window_create(o)` → `GC_unref(o)` → `darwin_window_register_numeric_id(h, id)`.
- if `o.asSheetOfId >= 0`: resolve the parent via `darwin_window_get_by_numeric_id(o.asSheetOfId)` and attach the new window as a modal/sheet via the same darwin attach-modal call B5b's `attachModal` arm uses (verify the exact fn name in the plan).
- return `(id, h)`.

`wmAllocSlot(): int32` = `result = gNextWindowId; inc gNextWindowId`.

The `zapp.nim` boot switches its `createWindow(opts)` call to `wmCreate(opts)` (so the boot and the runtime path share one allocator; keep `createWindow` as a thin alias only if anything else references it — otherwise rename).

### 3. `windowOptsApplyJson(o: WindowOptions, a: JsonNode)` (`native/nim/window.nim`)
Faithful Nim port of `window_opts_apply_json` — set each WindowOptions field from the JSON args when present (title/url/width/height/x/y/autoCenter/visible/resizable/.../backgroundColor/vibrancy/titleBarStyle/trafficLights/sidebar{Url,Material,Width,Min,Max,Collapsible,Collapsed}/inspector{...}/toolbarJson/asSheetOf/presentation/detents/grabber). Uses the nil-safe `{}` accessor + `getFloat(0).int32` for numeric dims (the B5b lesson: std/json `getInt` returns 0 for a JFloat; the bridge stores numbers as doubles). Pure (no native calls) → unit-testable.

### 4. router `__window:create` (t:1) (`native/nim/router.nim`)
In the t:1 chain (before the service fallthrough, alongside the other `__`-prefixed routes): when `f.m == "__window:create"`, build a `WindowOptions` (newWindowOptions + `windowOptsApplyJson(o, f.a)`), `wmCreate(o)`, then `sendInvokeResponse` with the success payload the runtime expects (mirror the zc `__window:create` response shape — confirm the exact JSON in the plan, likely `{"windowId":"win-<id>"}`).

### 5. router `__popover:create` (t:1) (`native/nim/router.nim`)
When `f.m == "__popover:create"`: parse `windowId`(→numeric via `darwin_window_numeric_id_for_string`, default = sender `windowId`), `url`, `behavior` (default `"transient"`), `width`(320)/`height`(400); if `url != ""`: `slot = wmAllocSlot()`, `host = darwin_window_get_by_numeric_id(target)`, if host non-nil call `darwin_popover_create(host, "pop-<slot>", url, w, h, behavior, target, slot)`; respond `{"popoverId":"pop-<slot>"}` (and an empty/again-shape response when url empty or host nil — mirror the zc). Closes the B8 `popover:create` deferral.

## Decomposition (2 tasks)

- **WM1 — core:** WindowOptions runtime fields + `wmCreate`/`wmAllocSlot` + `windowOptsApplyJson` + switch the `zapp.nim` boot to `wmCreate` + `native/nim/tests/windowmanager_test.nim` (stub `darwin_window_create`/`darwin_window_register_numeric_id`; assert id monotonicity, sidebar/inspector slot pre-alloc ONLY when the urls are set, `wmAllocSlot` monotonicity, and `windowOptsApplyJson` field mapping incl. fractional dims). Build + unit tests.
- **WM2 — routes + GATE:** router `__window:create` + `__popover:create` t:1 routes → full build → **human GATE on Nim** (`ZAPP_NATIVE_LANG=nim bun run dev`): `Window.create` opens a plain window; a window created with `sidebar`/`inspector` opts opens **with native chrome**; `createPopover().show()` shows a popover. Smoke vehicle: the kitchen-sink **Multi-window** section (+ optionally a "New window (sidebar shell)" variant added to it to exercise chrome-on-Nim).

## Testing & verification
- Unit: `windowmanager_test.nim` (run via `nim c -r`, like the other Nim module tests) for the pure allocation + JSON-mapping logic.
- Build: success only when the last line is `[zapp] build complete: <path>`.
- Regression: the full Nim unit-test suite stays green.
- Human GATE (WM2): the Nim-build payoff above. Also re-verify the **zc build** still opens windows/popovers (the WindowManager changes touch shared Nim modules but not the zc path; sanity only).

## Risks / open items
- **Response-shape fidelity:** the exact `dispatch_invoke_response` JSON for `__window:create` (and the empty-arg/failed `__popover:create` branch) must match what the TS runtime's `Window.create`/`createPopover` awaits — confirm against `router.zc` + `runtime/window.ts` in the plan, don't guess.
- **WindowOptions field audit:** `window_opts_apply_json` (window.zc:336-630) may set fields the Nim ref still lacks; the plan enumerates them so `windowOptsApplyJson` is complete (missing fields = silently-ignored opts, not a crash).
- **asSheetOf attach fn:** reuse the exact darwin attach-modal symbol B5b's `attachModal` arm calls; verify the name.

## Non-goals (this cycle)
- Initial-window-as-app-shell on Nim (deferred — see Scope).
- iOS sheet presentation/detents behavior (fields flow through for parity; macOS attach is the only live path this cycle).
- A Nim-side window handle map (the `.m` registry is the source of truth).
