# P3 — Nim-Windows port plan (roadmap gap #6)

**Branch:** `windows-nim` (worktree at `../zapp-nim`, off `origin/main` @ `481fa06`).
**Scoped:** 2026-07-09, all claims code-verified against the Nim tree + the legacy
`windows/*.c` reference. Companion to `2026-07-08-nim-migration-status.md` (the
Windows-team handoff) and `nim-migration-roadmap.md` gap #6.

**Goal:** make `zapp build --platform windows` on the **default (Nim) path** produce
a running `.exe` — replacing the `ZAPP_NATIVE_LANG=zc` escape hatch. The working
`native/platform/windows/*.c` are the **reference to wire in**, not to inherit.

---

## The gap in numbers (verified)

- Nim layer depends on **160 distinct C-ABI symbols**; **137 are `darwin_*`** platform
  symbols needing a Windows twin. 95 of them are declared in `router.nim` alone.
- **105 / 137 (77%) already have a name-matching `windows_*` impl** in the legacy tree
  — drop-in once the darwin_↔windows_ name split is resolved.
- **32 have no Windows impl** (the new-code backlog), concentrated in five buckets:
  `fs` (11, greenfield), `sidebar` (6), `inspector` (3), `notification` delivered-mgmt
  (3), `toolbar` (3, greenfield), `devtools` (2, greenfield), + 3 window shims
  (`zoom`/`focus`/`get_by_numeric_id`) and `darwin_windows_list_json`.
- The legacy Windows tree also carries machinery the Nim importc surface does **not**
  call yet: `titlebar` (10), `material`/theme (5), `power` (3), `jumplist` (2),
  deeplink/single-instance, webview internals, and `*_typed` variants. Decide per-feature
  whether the Nim port exposes these or leaves them dormant.
- **Zero** `when defined(windows)` / `zappWindows` conditionals exist in `native/nim/`.

## What's already in our favor

- `getPlatformSources("windows")` (`native.ts:148`) **already returns the 19
  `windows/*.c`** — the source list exists; it's just never wired into the Nim compile.
- A Windows **`libzjs_embed.a` already exists** at `C:\Users\Zach\zjs\build\windows\`
  — same archive name `renderPlatformNim` links on mac/iOS. The zjs link is available now.
- `jsonvalue.nim` (the JsonValue C-ABI) is pure Nim in the module graph — no per-build
  `zc transpile`, cross-platform by construction.
- The exact Windows compile flags + link libs are known verbatim (from `build.zc`):
  - compile: `-DUNICODE -D_UNICODE -DCINTERFACE -DCOBJMACROS -I<vendor/webview2/include>`
  - link: `ole32 shell32 uuid user32 gdi32 comctl32 comdlg32 shlwapi winhttp bcrypt
    advapi32 rpcrt4 crypt32 version windowscodecs shcore runtimeobject dwmapi`
- Reference impls are richer on `windows-parity-3` @ `2d881db` (jumplist + custom
  titlebar + window/webview improvements) than on `main` — pull those in (below).

---

## Two decisions to lock before executing

### D1 — C-ABI symbol strategy: **rename `windows_*` → `darwin_*`** (recommended)
Unify the C-ABI name so the Nim router stays platform-agnostic — exactly how
`darwin/*.m` and `ios/*.m` **both** already export `darwin_*` (the prefix is the
zapp native ABI name, file-split by platform, not literally "Darwin OS"). Nim files
untouched; one mechanical, reviewable/revertible commit across ~21 `.c/.h`.
- *Fallback if the rename proves noisy:* a force-included `windows/abi_darwin.h` with
  `#define darwin_window_show windows_window_show` × 105 (`-include` on the windows
  compile). Zero edits to `windows/*.c` or Nim; fastest to first-link; but 105 macros
  to maintain and it only covers the matching set (the 32 gaps still need real impls).
- *Rejected:* per-symbol `when defined(windows): {.importc:"windows_…".}` shims in Nim
  — 160 declarations to wrap, splits every Nim module.

### D2 — Nim C backend on Windows: **`--cc:gcc` (MinGW)** (recommended)
`buildNativeNim` hardcodes `--cc:clang` (`native.ts:1340`). The working zc Windows
build used MinGW gcc (15.2 present here); it's the lower-risk match for the WebView2
`CINTERFACE`/`COBJMACROS` C-ABI + the `.rsp` linking the zc path already proved. Make
the driver target-aware (`--cc:clang` on Apple, `--cc:gcc` on Windows). clang 20 is
also present as a fallback if MinGW link issues appear.

---

## Prerequisites (P0 — before any Windows-Nim build)

- **Install Nim on this box** — not present (`nim: command not found`). Use `choosenim`;
  pin to the version the mac session uses (confirm — repo has no explicit pin; `--mm:orc`
  implies Nim 2.x). clang 20 + MinGW gcc 15.2 + bun 1.3.14 are already installed.
- **Bring the improved reference `.c` in:** from `windows-parity-3` @ `2d881db`, pull
  `jumplist.c/.h`, `titlebar.c/.h`, and the improved `window.c`/`webview.c`/`menu.c`/
  `notification.c`/`platform.c` into this worktree's `native/platform/windows/`.

---

## Phased execution

### Phase A — Build plumbing: compile the `.c`, don't link yet
1. `nimDefinesForTarget("windows")` → `["-d:zappWindows"]` (`native.ts:51`); update
   `native.test.ts:30-32` (currently asserts `[]`).
2. `renderPlatformNim` **windows branch** (`build-config.ts:435`): emit `{.compile.}`
   lines for `windows/*.c` with the C compile flags above (NOT `-fobjc-arc`), the
   Windows `{.passL.}` lib list, and `{.passL: "${zjsBuildDir}/windows/libzjs_embed.a".}`.
3. Make the compiler backend target-aware in `buildNativeNim` (D2).
4. **Exit criterion:** every `windows/*.c` compiles to an object under the Nim-driven
   backend (defines/includes correct). Link failures are expected here.

### Phase B — Symbol unification + first link (the core milestone)
5. Execute D1 (rename `windows_*`→`darwin_*`, single commit).
6. Confirm the non-darwin glue resolves on Windows: `zjs_*`/`worker_*` (from
   `libzjs_embed.a` + `zjs.c`), `permissions_check`, `zapp_build_*` (generated),
   `zapp_worker_registry_*` (Nim exportc). The 3 `zapp_ios_*` are iOS-gated (skip).
7. **Exit criterion (Nim-Windows "M1"):** a minimal app links to a `.exe` that opens a
   window with WebView2 content — `platform_init/run` + `window_*` + `webview_*` path.
   Gate the 32 unimplemented symbols behind stubs if they block the link.

### Phase C — Fill the 32-symbol backlog (parity)
Priority order (boot-critical first):
- **window shims** (`zoom`, `focus`, `get_by_numeric_id`, `windows_list_json`) — thin
  wraps over existing `windows_window_*` (`get_webview`/`activate_app` are near-twins).
- **fs** (11, greenfield `windows/fs.c`) — needed for the fs service; sizeable.
- **notification** delivered-mgmt (3), **sidebar** (6), **inspector** (3) — chrome parity.
- **toolbar** (3), **devtools** (2) — greenfield; devtools low-priority (WebView2 has its
  own F12). Consider no-op stubs first.
- **Dormant machinery:** wire the committed `titlebar`/`jumplist` (+ material/power) into
  the Nim path as `darwin_*`-named entry points (or via the existing chrome-op dispatch),
  matching how they were dispatched from the `.zc` router.

### Phase D — Gate + cleanup
8. **Windows parity gate** (Nim-scoped): mirror `ios-platform-parity.test.ts`, but assert
   every `darwin_*` importc has a Windows definition (not a `.zc` scan).
9. Once Windows-on-Nim links **and runs**, roadmap **gap #7b** unblocks: delete the dead
   `native/**/*.zc` (currently the `=zc` source + scanned by 2 parity tests).

---

## Risks / open items
- **zjs reproducibility:** `libzjs_embed.a` exists but is tied to the local `zjs` checkout
  (`vendor/zjs` symlink → `C:\Users\Zach\zjs`). Overlaps handoff **P1** (vendor zc/zjs).
  zjs *development* is deferred to a parallel session; the *artifact* is enough to link.
- **Signature drift:** the 105 "matching" `windows_*` are matched by name/suffix. A rename
  surfaces any signature mismatch vs. the `darwin_*` importc decls at link — fix as thin
  shims where they differ.
- **Nim version parity** with the mac toolchain (no repo pin) — confirm before P0.
- **WebView2 runtime** must be present on the target machine (Evergreen or fixed-version).
