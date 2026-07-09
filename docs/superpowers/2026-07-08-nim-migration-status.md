# Zen-C → Nim migration status — merge-to-main / Windows-handoff assessment

**Branch:** `feat/nim-native` @ `aae75e1` · **Assessed:** 2026-07-09 · all claims verified against code.

**Decision framing:** Can we merge `feat/nim-native` → `main` and hand `main` to the Windows team?

**One-line answer:** Yes to the merge (clean fast-forward, macOS/iOS solid, gates green). But the Windows
team does **not** inherit a working Nim Windows build — they inherit a working *Zen-C* Windows build reachable
only via `ZAPP_NATIVE_LANG=zc`, plus a from-scratch Nim-Windows port to write. Nim-Windows is unstarted.

---

## 1. Build path & Zen-C status

### The macOS/iOS app build is Nim-only (confirmed)
- Default build routes through `useNimNative()` (`cli/src/native-lang.ts:13-15`): returns `true` unless
  `ZAPP_NATIVE_LANG=zc`. `compileNative` branches on it and **returns early into `buildNativeNim`**
  (`cli/src/native.ts:1381-1388`) — the entire legacy zc pipeline (`generatePlatformConfig`, `zc build`)
  below that point is never reached on the default path.
- `buildNativeNim` (`native.ts:1142-1347`) renders `.zapp/zapp_build_config.nim`, `zapp_bootstrap.nim`,
  `zapp_headless.nim`, `zapp_platform.nim`, `zapp_assets.nim`, then compiles `zapp/app.nim` via
  `nim c --cc:clang --mm:orc --threads:on` (`native.ts:1340-1345`), linking the platform `.m` sources through
  `renderPlatformNim` + `native/nim/zapp.nim`. The app's native entry is `zapp/app.nim`
  (`chooseNimRoot`, `native.ts:1110-1122`) — hard error if absent.
- **Correction to a starting finding:** the cited "`renderPlatformNim` accepts a windows target
  (build-config.ts:78-79)" is wrong. Lines 78-79 are `permsPlatform` (the permissions manifest platform tag).
  `renderPlatformNim` (`build-config.ts:435`) has **only** an `ios` branch and a fall-through `macos` branch —
  **no windows branch** (see §3).

### Zen-C compiler is not a build dependency of the Nim path (confirmed, with a caveat)
- `nim c` is the only compiler driver invoked; no `zc transpile`/`zc build` on the Nim path. The `JsonValue`
  C-ABI that used to require a per-build `zc transpile` is now `native/nim/jsonvalue.nim` (roadmap gap #2A).
- `zc` is **not vendored** — `vendor/` holds `bare/ cef/ webview2/ zjs/`, no `zc`. It happens to be installed
  on this dev machine at `/usr/local/bin/zc`, but a clean clone / the Windows team's machines would not have it.
  **Consequence:** the `ZAPP_NATIVE_LANG=zc` escape hatch (the only working Windows path today) requires the
  Windows team to obtain + install the `zc` compiler separately — it is not in the repo.

### `native/**/*.zc` (43 files) are dead for the build, but still load-bearing for tests + the Windows fallback
- Truly not compiled/imported by the Nim build (early-return above). Last commit touching any of them:
  `0261c38`, 2026-06-19 — frozen.
- **They are NOT free to delete yet.** They remain (a) the source the `ZAPP_NATIVE_LANG=zc` Windows build
  compiles, and (b) the scan target of `ios-platform-parity.test.ts` and `windows-platform-parity.test.ts`
  and `test-native.ts`. Roadmap gap #7b explicitly gates `.zc` deletion on Windows-on-Nim landing.

### Service codegen is still `.zc`-only — a real Nim-DX gap (confirmed)
- `generate.ts` `scanServices`/`collectZcFiles` (`generate.ts:19-71`) walks the app's `zapp/**` for **`.zc`
  files only**, regex-matching `.service.add("name", handler)` to emit typed TS wrappers in `src/zapp/*.ts`.
  **There is no Nim scanner** — it never reads `app.nim`. `generateBindings` runs unconditionally on dev/build/
  generate (`zapp-cli.ts:230,558,723`), independent of `useNimNative()`.
- Runtime service *registration* is fine in Nim: `app.service.add` → `service.nim:36-38` → linear-scan
  registry; `service_get_manifest_json` feeds the webview. So services **work** at runtime.
- What's missing is the *typed binding* codegen for Nim-authored services. Proven by the two in-repo apps:
  - **cef-hello** (Nim-only, no `app.zc`): has **no** `src/zapp/` bindings; calls
    `Services.invoke<string,{name}>("greet", …)` by string (`examples/cef-hello/src/main.ts:57`). Works, untyped.
  - **kitchen-sink**: keeps a vestigial `zapp/app.zc` (`app.service.add("greet", greet)`) that the Nim build
    never compiles, **solely** so codegen emits `src/zapp/Greet.ts`. Its `app.nim` also registers
    `openInfoWindow`, which — absent from `app.zc` — gets **no** typed binding.
- **Verdict:** `.zc` is not required for a Nim app to *run*, but is currently required to get *type-safe*
  service bindings. Nim apps must either ship a parallel `app.zc` or drop to string-keyed `Services.invoke`.

---

## 2. Subsystem parity — dock / menu / panel / screen / tray / sync / log

These have no dedicated `native/nim/*.nim` module; they are dispatched inline from `router.nim`. Verified that
each Nim dispatch imports the same `darwin_*` C entry point the `.m` impl exports, and that the corresponding
`.zc` was a thin dispatch→impl passthrough (logic lives in the `.m`, which the Nim build also links). macOS
end-to-end is proven by kitchen-sink running on the Nim build.

| Subsystem | Nim dispatch | `.zc` was… | macOS parity | Notes |
|---|---|---|---|---|
| **menu** | `router.nim:92-93` → `darwin_menu_set_from_payload` (defined `darwin/menu.m:407`) | thin (`menu.zc` calls `darwin_menu_set_typed`) | ✅ OK | Nim uses a *newer payload-JSON* C-ABI; `menu.m` carries both entry points. Logic in `.m`. |
| **tray** | `router.nim:97-104` → `darwin_tray_*_from_payload` (`darwin/tray.m:457`) | thin (`tray.zc` is 1:1 forwarders) | ✅ OK | Pure passthrough; logic in `.m`. |
| **screen** | `router.nim:84-86,442-458` → `darwin_screen_*_json` | thin **but** `screen.zc:6-61` holds BOTH `darwin_*` and `windows_*` branches + a `sscanf("win-%d")` | ✅ OK (macOS) | The Windows branch lives only in `.zc` — see §3. macOS logic in `.m`. |
| **dock** | `router.nim:111-118` → `darwin_dock_*` | thin | ✅ OK | Passthrough. |
| **panel** | `router.nim:122-132,466-505` → `darwin_panel_*` | thin (`panel.zc`) | ✅ OK | Passthrough. |
| **sync** | `router.nim:106-108` → `darwin_sync_handle(action,payload)` (`darwin/sync.m:224`) | thin | ✅ OK | Raw-payload passthrough; logic in `.m`. |
| **log** | **none** — `zapp_log_init()` emitted as a **no-op** (`build-config.ts:231`); no `log.nim` | `native/log/log.zc` + `native/shared/log.zc` exist | ⚠️ Not ported | Native log subsystem is a no-op stub in the Nim path. Diagnostic-only; CLI has its own `clog`. Low impact but a genuine "not reproduced" item. |

**Parity conclusion:** dock/menu/panel/screen/tray/sync are thin dispatch→`.m` and fully functional on macOS Nim
(no lost parsing/state/validation — that logic always lived in the `.m`). **log** is the one true gap: the
native logging subsystem is not reproduced (no-op init), though it is diagnostic-only. Roadmap corroborates:
"every leaf service … matching `*.nim` each" and "macOS module parity is essentially complete."

---

## 3. Windows-on-Nim verdict: FROM SCRATCH (not a working scaffold)

Windows is **not buildable via the Nim path today.** Every layer is macOS/iOS-shaped:

1. **`renderPlatformNim` has no windows branch** (`build-config.ts:435-521`). `const ios = isIOSTarget(target)`;
   non-iOS falls through to the macOS block, which hardcodes `-framework Cocoa -framework WebKit …`
   (`build-config.ts:497-500`) and links `libzjs_embed.a` for macOS. Called with `target="windows"` it would
   emit **Cocoa frameworks + `-fobjc-arc` on `.c` files** — a broken link on Windows.
2. **The Nim layer is 100% darwin-symbol.** `router.nim` alone has **200** `darwin_*` `importc`s; every leaf
   `*.nim` imports `darwin_*`. **Zero** `when defined(windows)` / `zappWindows` conditionals anywhere in
   `native/nim/` (grep: no matches). `nimDefinesForTarget` only handles iOS (`-d:zappIos`), nothing for windows.
3. **The working Windows impls export the wrong symbol namespace for Nim.** `native/platform/windows/*.c`
   define **`windows_*`** functions (`windows_window_create`, `windows_webview_create`, …;
   `window.c` has **0** `darwin_*` definitions). The Nim router imports `darwin_window_create` etc. — those
   symbols do not exist in `windows/*.c`, so even if the sources were compiled the link would fail on undefined
   `darwin_*`. The `windows_*` impls are dispatched **only** from the `.zc` router's `@cfg(windows)` branches
   (e.g. `screen.zc:14-61`). `native/platform/windows` is referenced **nowhere** in `native/nim/`.
4. **No evidence of a Windows Nim build ever being exercised** — no CI, test, doc, or script. The iOS
   parity gate (`ios-platform-parity.test.ts`) is iOS-scoped and scans `.zc`, not Nim. `windows/*.c` last
   changed 2026-06-19; it is reachable only from the frozen `.zc` path.

**Corroborated by the repo's own roadmap** (`docs/nim-migration-roadmap.md`): gap #6 "**Windows** — Large —
No Windows in the Nim path at all (no MinGW/`cc` handling, no `windows/*.c` compile, no WebView2 link)"; and the
header: "**Windows-on-Nim is in progress** … until that sprint lands, build Windows with `ZAPP_NATIVE_LANG=zc`."

**Bottom line for the handoff:** taking `main` today, the Windows team gets:
- a **working Windows app** *only* if they (a) install `zc` themselves (not vendored) and (b) set
  `ZAPP_NATIVE_LANG=zc` — i.e. the legacy Zen-C build against `windows/*.c`. This is the real, functional
  Windows implementation, but it sits behind the escape hatch and depends on an un-vendored compiler.
- a **from-scratch Nim-Windows port** to write if the goal is Windows-on-the-default-path: add a windows
  branch to `renderPlatformNim` (Win libs not Cocoa, MinGW/`gcc` driver not `--cc:clang`, WebView2 link,
  `.rsp` handling already exists in the zc path as a reference), add `when defined(windows)` dispatch (or a
  `windows_*` importc shim) across ~15 Nim modules, wire `nimDefinesForTarget("windows")`, and rename or
  bridge the `windows_*`↔`darwin_*` symbol split.

---

## 4. Merge-to-main blockers

**Distance:** `feat/nim-native` is **836 commits ahead of `main`, 0 behind**; `main` (`dd09951`) **is an
ancestor of HEAD** → merge is a clean **fast-forward** (no rebase, no conflicts). Diff: 459 files, +80,868/−3,964.

**Gates (run 2026-07-09):**
- `bun run check` (tsc `--noEmit` × 2 projects): **PASS** (exit 0, clean).
- `bun run test` (cli/src + runtime): **PASS** — **292 pass / 0 fail**, 28 files.
- Not run here: `bun run test:native` (`nim r` over 20 `native/nim/tests/*.nim`) — macOS Nim unit tests;
  worth running on the merge host to confirm the Nim toolchain is present.

| Item | Tag | Detail |
|---|---|---|
| Merge mechanics (FF, conflicts) | — | **None.** Strictly ahead, fast-forwardable. |
| `bun run check` / `bun run test` | — | **Green.** No blocker. |
| **Windows on the default (Nim) path** | **[Windows-team]** | Unstarted (§3). Default build for `target=windows` is broken; Windows must use `ZAPP_NATIVE_LANG=zc`. This is the long pole, not a merge blocker. |
| **`zc` not vendored** | **[required-for-Windows]** | The only working Windows path (`=zc`) needs a `zc` compiler that isn't in the repo. Vendor a prebuilt `zc`, or document install, before handing Windows off. Also blocks any clean-clone `=zc` build. |
| **Service codegen has no Nim scanner** | **[required-for-DX]** | Nim-authored services get no typed TS bindings; apps keep vestigial `app.zc` (kitchen-sink) or use string `Services.invoke` (cef-hello). Not a runtime blocker; is a migration-completeness gap. Add a `app.nim` scanner to `generate.ts`. |
| **Native `log` subsystem no-op in Nim** | **[cosmetic]** | `zapp_log_init` stubbed; no `log.nim`. Diagnostic-only. |
| **Dead `native/**/*.zc` deletion** | **[cosmetic, but blocked]** | Cannot delete yet: still the `=zc` Windows source + scanned by 2 parity tests + `test-native.ts` (roadmap #7b gates deletion on Windows-on-Nim). Deleting now would remove the Windows fallback. |
| **Vestigial `kitchen-sink/zapp/app.zc` + `app.zc`/`build.zc`** | **[cosmetic]** | Kept only for codegen/`=zc`; harmless. Cleans up once codegen gains a Nim path. |

**Merge recommendation:** **Ready to merge to `main` now** — macOS/iOS parity is essentially complete, the merge
is a clean fast-forward, and both CI gates are green. **But do not represent `main` as a working Windows
handoff.** Before the Windows team can be productive, resolve two required items: **(1) vendor/ship `zc`** (or
document its install) so the `ZAPP_NATIVE_LANG=zc` Windows build is reproducible on their machines, and **(2)**
scope the Nim-Windows port (roadmap gap #6) as their actual first deliverable — they will be building it, with
the working `windows/*.c` impls behind the `.zc` path as the reference to port from, not inherit.

---

## Migration % — estimate & reasoning

- **macOS: ~98%.** Every zc responsibility has a working Nim counterpart; kitchen-sink + cef-hello run fully on
  Nim; Nim is ahead of zc on several features. Residual: native `log` no-op, service-codegen Nim scanner.
- **iOS: ~90%.** Nim path threads iOS SDK/flags (`-d:zappIos`, `ios/*.m` export `darwin_*`); parity gate exists.
  Not independently re-verified in this pass (macOS-only smoke here).
- **Windows: ~5% (Nim path).** Working impl exists in `windows/*.c` but only under the frozen `.zc` build; the
  Nim path has zero Windows support.
- **Overall (weighted toward the two shipping platforms + the stated Windows goal): ~75–80%.** The remaining
  ~20-25% is almost entirely the Windows-on-Nim port (gap #6) plus its downstream zc-removal (gap #7b), with a
  thin slice of Nim-DX polish (service codegen, log).

---

## Windows Team Punch-List

Ordered pickup list to make `main` a productive Windows base. **P1 and P2 are small prerequisites the current owner should land before/at handoff; P3 is the Windows team's main first project.**

### P1 — Vendor + document the `zc` compiler   `[required · small · pre-handoff]`
- **Why:** the only working Windows build today is `ZAPP_NATIVE_LANG=zc` compiling `native/platform/windows/*.c`, and `zc` is **not in the repo** (only on the original dev's machine at `/usr/local/bin/zc`). A clean clone cannot build Windows at all.
- **Do:** vendor a prebuilt `zc` under `vendor/zc/` (or document the exact source + version + install in the Windows build docs), and add a `zapp build --platform windows` (`=zc`) smoke a fresh clone can run.
- **Acceptance:** a teammate on a clean machine builds the Windows app via `ZAPP_NATIVE_LANG=zc` with no external `zc` install beyond the repo.
- **Where:** `vendor/`, the `=zc` path in `cli/src/native.ts`, Windows build docs.

### P2 — Service-codegen Nim scanner   `[required for Nim DX · small–medium]`
- **Why:** `generate.ts` scans only `.zc` files for `service.add(...)` → typed TS wrappers. Nim apps (authoring `zapp/app.nim`) get runtime registration but **no typed `Services.invoke` bindings** — so a Windows Nim app either keeps a vestigial `app.zc` (as kitchen-sink does) or drops to string-keyed invokes (as cef-hello does).
- **Do:** extend `scanServices`/`collectZcFiles` to also collect `.nim` and regex `app.service.add("name", handler)`, emitting the same `src/zapp/*.ts` wrappers.
- **Acceptance:** cef-hello (Nim-only, no `app.zc`) gets a typed `Greet.ts`; kitchen-sink's vestigial `zapp/app.zc` can be deleted.
- **Where:** `cli/src/generate.ts:19-71`.

### P3 — Nim-Windows port (the main project)   `[large · Windows-team's first deliverable · roadmap gap #6]`
- **Why:** Windows is 0% on the Nim path — `renderPlatformNim` has no windows branch, `native/nim/` is 100% `darwin_*` importc with zero `when defined(windows)`, and `windows/*.c` export `windows_*` symbols the Nim router never calls. The working impls behind `.zc` are the **reference to port from, not inherit.**
- **Do (steps):**
  1. **`renderPlatformNim` windows branch** (`cli/src/build-config.ts:435`): Win libs (not `-framework Cocoa/WebKit`), MinGW/`gcc` driver (not `--cc:clang`), WebView2 link, `.rsp` handling (the `.zc` path is a reference). Add `nimDefinesForTarget("windows")` → `-d:zappWindows`.
  2. **Resolve the C-ABI symbol split.** RECOMMENDED: rename `windows/*.c` `windows_*` → `darwin_*` (unify the C-ABI name so the Nim router stays platform-agnostic — the `.m`/`.c` split stays at the file level, exactly like macOS `darwin/*.m` vs iOS `ios/*.m`). Alternative: a `when defined(windows)` importc shim mapping `darwin_*`→`windows_*` across the ~15 Nim modules (more churn, keeps the split visible).
  3. **Wire `native/platform/windows/*.c` into the Nim compile list** (the macOS `darwin/*.m` wiring in `renderPlatformNim` is the template).
  4. **Windows parity gate** — mirror `ios-platform-parity.test.ts`, but Nim-scoped (assert every `darwin_*` importc has a Windows definition).
- **Then (gap #7b):** delete the dead `native/**/*.zc` once Windows is on Nim (currently blocked — it's the `=zc` Windows source + scanned by 2 parity tests + `test-native.ts`).
- **Reference material:** `native/platform/windows/*.c` (working impls) + the `.zc` `@cfg(windows)` router branches (e.g. `native/screen/screen.zc:14-61`) show the dispatch shape; `docs/nim-migration-roadmap.md` gap #6.

**Sequencing:** P1 unblocks the reference build on their machines; P2 unblocks typed Nim DX; P3 is the port itself. P1+P2 are hours-to-a-day each; P3 is the sprint.
