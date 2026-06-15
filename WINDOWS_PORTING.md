# Windows Porting Guide

State of the Windows port and the handoff brief for the Windows parity
sprint (task #167 / competitive-plan T2.C).

**Status update 2026-06-11 (Windows sprint, `windows-parity` branch):
M0–M2 are DONE and runtime-verified on a real Windows 11 machine.**
`bun run build` in hello-world (no flag needed — win32 hosts default to
the windows target) produces a working .exe: window + WebView2 + bridge
ready-handshake + `greet` round-trip, native Win32 menus, and headless
bare-quickjs workers end-to-end (embedded script load, libuv timers,
worker console, supervisor restart/gave-up contract, sync dispatch to
workers). All 60 `windows_*` symbols referenced from Zen-C are defined
(enforced by `cli/src/windows-platform-parity.test.ts`); the Tier 1
link gate below is CLOSED. Remaining gaps are Tier 2 feature breadth
(M3) and packaging/CI (M4). See "Windows prerequisites" and the
"Vendor/upstream ledger" sections below before building on a fresh PC.

macOS is the reference platform with full coverage; iOS shares most of
the Zen-C layer.

For general framework orientation read [`SKILLS.md`](SKILLS.md) and
`docs/architecture.md`. This file is Windows-specific.

## What exists today

```
native/platform/windows/        # 7 C translation units, v1-era
  platform.{c,h,zc}  window.{c,h,zc}  webview.{c,h,zc}
  dialog.{c,h,zc}    menu.{c,h}       notification.{c,h}   sync.{c,h}
vendor/webview2/                # WebView2.h + EnvironmentOptions + lib/x64 static loader
old/src/platform/windows/       # v1 implementation — reference for Win32 shapes only
cli/src/native.ts               # --platform windows accepted; getPlatformSources
                                #   lists the 7 .c files (filtered by existsSync)
zapp/build.zc templates         # windows cflags/link lines already generated:
  //> windows: cflags: -DUNICODE -D_UNICODE -DCINTERFACE -DCOBJMACROS
  //> windows: link: -lole32 -lshell32 -luuid -luser32 -lgdi32 -lcomctl32 ...
```

The npm-published `@zappdev/cli` already ships `vendor/webview2` in its
tarball, so the loader story is solved for distribution.

## The gap inventory — two tiers

### Tier 1: link-required `windows_*` symbols (the build gate)

These are referenced from shared Zen-C in `#else` (non-Apple) branches —
a Windows build of current main does not LINK until all exist:

```
windows_window_set_bridge_ready   windows_window_id_string
windows_window_eval_js            windows_window_load_url
windows_webview_eval_all          windows_webview_set_drag_region
windows_open_external             windows_sync_handle
windows_dialog_extract_args       windows_dialog_open_file
windows_dialog_save_file          windows_dialog_message
windows_menu_set_from_payload     windows_menu_show_context_from_payload
windows_notification_show         windows_notification_schedule
windows_notification_cancel       windows_notification_cancel_all
windows_notification_get_permission
windows_notification_request_permission
windows_notification_register_category
windows_notification_remove_category
windows_notification_set_bridge_ready
```

Some may exist in the v1-era .c files — verify signatures against the
current `darwin/` counterparts (several changed: e.g. window ids are now
canonically `"win-<numericId>"` strings, and `set_bridge_ready` matching
broke on macOS when the formats diverged — see Lessons below).

### Tier 2: Apple-only feature routes (silent no-ops on Windows)

router.zc has ~43 `#ifdef __APPLE__` blocks; most have NO `#else` — those
routes compile on Windows and silently do nothing. Each is a parity work
item. By feature area, with the darwin source of truth and the Windows
candidate tech:

| Area | darwin module | Windows candidate |
| --- | --- | --- |
| Tray | tray.m | `Shell_NotifyIcon` + popup menu |
| Global shortcuts | shortcuts.m (Carbon) | `RegisterHotKey` |
| Clipboard (text/html/image/files) | clipboard.m | `OpenClipboard` family |
| Screen/Displays API | screen.m | `EnumDisplayMonitors` / `GetMonitorInfo` |
| Theme detection + THEME_CHANGED | theme in app/webview | registry `AppsUseLightTheme` + `WM_SETTINGCHANGE` |
| Power/battery events | power.m (IOKit) | `RegisterPowerSettingNotification` |
| Auto-launch | autolaunch.m (SMAppService) | Run registry key / startup folder |
| Single instance | LSMultipleInstancesProhibited | named mutex + `WM_COPYDATA` handoff |
| Deep links | Info.plist schemes + AppDelegate | registry protocol handler + `WM_COPYDATA` |
| Dock badge/bounce | dock.m | `ITaskbarList3` |
| Custom protocols (zapp:// + user) | protocol.m | `ICoreWebView2` WebResourceRequested |
| Embedded webviews (`<zapp-webview>`) | panel.m | child `ICoreWebView2Controller` w/ bounds |
| Window sheets/modals | window.m beginSheet | owned modal window (no native sheet idiom) |
| Native sidebar / toolbar / popover | sidebar.m / toolbar.m / popover.m | **explicit non-goal for the sprint** — document as macOS-only chrome; revisit analogues later |
| Window metrics CSS vars | webview.m metrics script | titlebar metrics + **`--zapp-window-controls-inset-right`** (caption buttons are on the RIGHT — the var was named for this) |
| fs module path expansion + allowlist | fs.zc (POSIX `~`, `$userData`) | Win32 paths, `%APPDATA%`; the PERMISSIONS gates themselves are shared Zen-C and carry over free |
| Packaging/signing | notarize.ts / package.ts | SignTool / Azure Trusted Signing; MSIX vs portable exe decision |

## What transfers for free (don't rebuild)

- **Bridge protocol** (7 message types, cancellation, PERMISSION_DENIED
  contract), **router**, **services**, **permissions gates**, **events
  dispatcher shape**, **worker registry** — all shared Zen-C/TS.
- **runtime/ + bootstrap/** TypeScript — platform-agnostic by design. The
  webview bootstrap only needs the native side to provide: document-start
  script injection, script-message channel, and eval.
- **Workers:** `zjs` (default) RETAINED its libuv event loop for
  Linux/Windows when macOS moved to kqueue+CFRunLoop (zjs.c documents both
  paths) — but the Windows path is untested and needs a libuv dependency
  story on Windows (vendored? static?). `bare-v8` is the JIT option;
  `bare-quickjs/mqjs/hermes` claim Windows support, untested. `bare-jsc`
  is Apple-only. Worker host objects in engine files still carry
  `#ifdef __APPLE__` placeholders pending the `zapp_*` platform layer.

## WebView2 ↔ WKWebView mapping (the bootstrap contract)

| Need | WKWebView (darwin) | WebView2 |
| --- | --- | --- |
| Document-start scripts (bootstrap, windowId, pane markers, metrics vars) | WKUserScript atDocumentStart | `AddScriptToExecuteOnDocumentCreated` |
| JS → native messages | WKScriptMessageHandler "zapp" | `add_WebMessageReceived` / `postMessage` |
| native → JS eval | evaluateJavaScript | `ExecuteScript` |
| zapp:// scheme + brotli assets | WKURLSchemeHandler | `AddWebResourceRequestedFilter` (use the `_22` source-kinds variant) |
| Static loader | n/a | `WebView2LoaderStatic.lib` (vendored, x64) |

## Lessons from the macOS cycles that BIND the Windows port

These were bugs on macOS; the Windows implementation must respect them
from day one:

1. **Window ids are canonically `"win-<numericId>"` everywhere** — JS
   identity, dispatch-table registration, bridge-ready matching, event
   payloads, click payloads. macOS focus events were broken for weeks
   because one delegate kept a pointer-formatted id (`win-0x…`) that the
   ready-route string-match never hit.
2. **Broadcasts iterate a registered-webview dispatch table, not a
   top-level window walk.** `darwin_webview_eval_all` originally walked
   windows checking `contentView` — it silently missed every webview not
   mounted as the root view. `windows_webview_eval_all` must be
   registry-backed from the start.
3. **Identity/role markers must be document-start scripts, not one-shot
   evals** — a one-shot eval lands in the throwaway pre-navigation context
   and is wiped at commit. WebView2's `AddScriptToExecuteOnDocumentCreated`
   is the equivalent; it persists across navigations like WKUserScript.
4. **`dispatchWindowEvent` takes BARE event suffixes** ("focus",
   "sidebar-collapsed") — bootstrap prepends `window:`. Passing prefixed
   names dispatches `window:window:*` and silently matches nothing.
5. **No fixed-size buffers for outgoing JS/JSON** — the repo has a history
   of 512B/3KB/4KB truncation bugs (zapp_escape_dup heap allocator is the
   pattern; `darwin_dialog_extract_args`'s 4KB static buffer is a watched
   legacy exception). Don't add new ones in windows/*.c.
6. **Main-thread funneling:** WebView2 is STA/UI-thread-bound like AppKit.
   macOS uses dispatch_async(main); Windows needs the
   `PostMessage(WM_ZAPP_TASK)` + (for sync) event-wait pattern, with a
   same-thread short-circuit to avoid self-deadlock.

7. **Embedded webviews (`<zapp-webview>` panels) need their own child
   HWND for z-order.** macOS adds the child `WKWebView` as a subview
   (subview order = z-order, content shows on top for free). On Windows a
   second `ICoreWebView2Controller` parented to the *same* HWND as the host
   webview renders **behind** the opaque host surface — events fire, nothing
   paints. Fix (`platform/windows/panel.c`): give each panel an intermediate
   `WS_CHILD | WS_CLIPSIBLINGS` window, parent the controller to it, and
   `SetWindowPos(HWND_TOP)` it above the host on every bounds update + show.
   Bounds arrive as CSS px (host viewport, top-left) and convert to physical
   px via the controller's `RasterizationScale` (= DPI/96). The runtime
   tracker places the panel at the element's *viewport* position, so a panel
   whose `<zapp-webview>` is scrolled below the fold is correctly positioned
   off-screen (child-clipped) until scrolled into view — that is not a bug.
   Controller creation is async: buffer bounds/show/url and apply them in the
   completed handler. Reuse the host's cached `ICoreWebView2Environment`
   (`zapp_get_webview_environment()`) so panels share its user-data store.
   Derive the CSS→physical scale from `GetDpiForWindow(owner)/96`, NOT the
   controller's `RasterizationScale` — the latter reads a stale 1.0 for the
   first frames after creation (monitor scale not yet detected), which placed
   panels up-left on >100% displays until a later event refreshed it. After
   moving the child window, call `NotifyParentWindowPositionChanged` or
   WebView2 composites at the stale screen position until an unrelated event.

8. **Win11 window material is DWM attributes + a transparent web surface.**
   macOS vibrancy mounts an `NSVisualEffectView`; Windows has no widget — it's
   `DwmSetWindowAttribute`. The `vibrancy` option drives
   `DWMWA_SYSTEMBACKDROP_TYPE` (Mica/Acrylic) and the app theme drives
   `DWMWA_USE_IMMERSIVE_DARK_MODE` (re-applied to every window on the
   `WM_SETTINGCHANGE`/`ImmersiveColorSet` theme flip). Crucially the backdrop
   only shows where the **web content is transparent** — set the host
   controller's `DefaultBackgroundColor` to `{0,0,0,0}` via
   `ICoreWebView2Controller2` (`webview.c`) AND the page must use a transparent
   CSS background, the exact same opt-in as macOS vibrancy. All DWM calls
   no-op gracefully on Win10 / pre-22H2 (`platform/windows/material.c`).

9. **`TaskDialogIndirect` (modern message dialog) needs comctl32 v6 — and
   statically importing it bricks app launch.** zapp has no application
   manifest, so the loader binds `-lcomctl32` imports to comctl32 **v5.82**,
   which doesn't export `TaskDialogIndirect` → unresolved import → the EXE
   exits instantly before `main`, no error output. Fix (`dialog.c`): resolve it
   **dynamically** (`GetProcAddress`) — never via the import lib — after
   activating a comctl32 v6 activation context. Build that context from a tiny
   Common-Controls-6.0.0.0 manifest written to a temp file (deterministic; the
   "borrow shell32's manifest resource" trick relies on an undocumented
   resource ID and silently returned a v5 module here). Activate the context
   again around the call so the dialog is themed. Falls back to `MessageBoxW`
   if resolution fails. `IFileOpenDialog`/`IFileSaveDialog` (shell COM) and
   WinRT toasts are already modern without any of this.

10. **Native sidebar/inspector = child-HWND split, not a widget.** macOS uses
    NSSplitViewController with .sidebar/inspector items hosting host-twin
    WKWebViews. Windows has no split control, so `platform/windows/sidebar.c`
    carves the client area into `[sidebar | splitter | content | splitter |
    inspector]` child HWNDs, each hosting a WebView2 controller. The panes are
    full host-twins via `windows_webview_create_ext` (own pre-allocated
    transport slot, host JS identity) — NOT sandboxed panels. The host webview
    moves into a content child window so the layout owns its bounds; `WM_SIZE`
    reflows, `WM_MOVE` re-notifies every controller. Splitters are thin
    `WS_CHILD` windows (SIZEWE cursor) that `SetCapture` on mousedown and
    resize the pane on drag (clamped to min/max). Collapse/expand hide the pane
    + its splitter and give the space to content. Control ops
    (`windows_sidebar_*`/`windows_inspector_*`) are the router entry points;
    collapse/resize emit `dispatchWindowEvent('win-<host>', …)` into both panes
    (parity with darwin `zapp_pane_emit`). Relative window/pane URLs
    (`#route`, `?q`) must be resolved against the app base with `UrlCombineW`
    (`zapp_resolve_nav_url`) — WebView2 `Navigate` needs an absolute URL, unlike
    WKWebView's `URLWithString:relativeToURL:`.

## Native-UI follow-ups (next list)

As of 2026-06-14, every macOS/iOS native surface has a Windows implementation
(window material/vibrancy → Mica/Acrylic + immersive dark caption, modern
TaskDialog + IFileDialog, Win32 menus/tray, WinRT toasts, dock → taskbar
badge/bounce/progress/show-hide, `<zapp-webview>` panels, sidebar + inspector
split panes, popover/flyout, power/deep-links/screen/clipboard/shortcuts).
Remaining native work, in rough priority:

1. **Custom / extended title bar (Tier 2).** The one big remaining native item
   and the highest-risk: `DwmExtendFrameIntoClientArea` + `WM_NCCALCSIZE`
   caption removal, self-drawn min/max/close caption buttons, `WM_NCHITTEST`
   for drag (`HTCAPTION`) / resize borders / Snap Layouts (`HTMAXBUTTON`).
   Unlocks content-under-caption, themed caption buttons, and makes
   `--zapp-window-controls-inset-right` non-zero (currently injected at 0;
   webview.c metrics block is ready for it). Needs heavy interactive visual
   iteration (drag/resize/maximize/Snap) — do it deliberately, ideally after a
   clean regression baseline. The web drag-region machinery
   (`windows_webview_set_drag_region`/`zapp_is_in_drag_region`) is present but
   currently inert — wire it via WM_NCHITTEST here.
2. **Taskbar jump lists** (`ICustomDestinationList`) + **thumbnail toolbar**
   (`ITaskbarList3::ThumbBarAddButtons`). Windows-only polish; needs a small
   app-facing config surface (tasks/recent items). No macOS analog.
3. **Snap Layouts** — mostly comes free once the custom title bar's maximize
   button reports `HTMAXBUTTON`.

macOS to-do queued from the Windows side:
- **`backgroundColor` window option**: exists cross-platform (runtime type +
  `window.zc`), wired on Windows (WebView2 DefaultBackgroundColor). macOS/iOS
  parse it but no-op — wire to `NSWindow.backgroundColor` /
  `WKWebView.underPageBackgroundColor`.
- White-on-resize is inherent WebView2 async-repaint (no "repaint faster"
  knob); the `backgroundColor` option is the mitigation (gap color, not white).

## Open questions for the brainstorm (decide these first)

1. **Toolchain:** does `zc` (Zen-C 0.4.4+) actually run on Windows, and
   against which C compiler? The existing cflags (`-DCOBJMACROS
   -DCINTERFACE`, `-l` link style) imply clang/gcc-style C COM, not
   MSVC `cl`. Candidates: llvm-mingw, clang targeting MSVC ABI, or MSYS2.
   **Verify zc + clang + a hello-window link before anything else (M0).**
2. **Dev loop:** Bun + Vite run fine on Windows; `zapp dev` spawns the
   binary — confirm the spawn/env/log plumbing (cli passes ZAPP_LOG env;
   Bun.spawn env snapshot gotcha applies).
3. **zjs-on-Windows libuv:** vendor libuv? static link? Or revisit the old
   idea of WebView2-native web workers as the Windows default engine
   (memory: project_windows_webview2_workers) with zjs opt-in?
4. **CI gate:** mirror the ios-simulator pattern — a `windows-latest`
   GitHub Actions job that builds hello-world, plus a
   `windows-platform-parity.test.ts` mirroring the iOS one (#281): every
   `windows_*` referenced from `.zc` must be defined in
   `native/platform/windows/`.
5. **Milestone slicing (proposal to refine):**
   - **M0** — toolchain smoke: zc + compiler + WebView2 loader link on PC.
   - **M1** — hello-world boots: window + WebView2 + bridge + `greet`
     round-trip + Tier-1 symbols all real.
   - **M2** — events + workers: window events via WndProc, zjs worker
     end-to-end, Events bus cross-context.
   - **M3** — table stakes: tray, shortcuts, notifications, theme,
     clipboard, dialogs, single-instance, deep links, fs paths.
   - **M4** — ship: icon/resources, packaging (MSIX vs exe), signing, CI
     gate, docs + README platform table flip.
6. **Scope fences:** native-chrome trilogy = documented no-op (the runtime
   APIs already exist and the options are ignored gracefully); iOS-style
   per-feature stubs keep the link green as new macOS features land —
   consider requiring `windows/*.c` stubs in the same commit the way
   ios stubs are required today.

## Where to look while porting

- The current `darwin/` module for each feature is the source of truth —
  v2 architecture. `old/src/platform/windows/` is v1: read for Win32
  shape (WndProc, COM init, WebView2 embedding), never port line-by-line.
- `docs/architecture.md` "Verifying native changes" — extend it with the
  Windows gate once it exists.
- Wire contracts live in: `bootstrap/webview.ts` (message envelope,
  dispatchWindowEvent), `native/bridge/dispatch.zc` (broadcast fanout),
  `native/app/router.zc` (every route the platform must back).

## Windows prerequisites (verified 2026-06-11, first working build pass)

The goal: someone on a stock Windows 11 machine gets zapp building with
clear steps and no source surgery. Current requirement set:

- **MinGW-w64 gcc** (scoop `mingw`, tested 15.2.0) — `zc`'s default C
  compiler drives the whole app link, so the bare engine build is
  pinned to the same toolchain (Ninja + gcc; see `ensureBareBuilt`).
  MSVC/clang-cl is NOT the supported path — mixing MSVC-built C++
  statics into the MinGW link fails.
- **cmake ≥ 4** + **ninja** (scoop) — bare engine build.
- **NASM** (scoop `nasm`) — vendor/bare's `CMakeLists.txt` does
  `enable_language(ASM_NASM)` on win32-x64 at configure time, even
  though BoringSSL asm is disabled (below).
- **bun**, **git**; `git submodule update --init vendor/bare`.
- **Zen-C (`zc`)** built from source: `cmd /c build.bat` with
  `ZC_HAS_JIT=0` unless libtcc is installed. Keep the checkout current
  — zapp tracks recent zc.

## Vendor/upstream ledger — DO NOT patch vendors locally

Policy (2026-06-11): vendored/third-party code (Zen-C, zjs, bare,
BoringSSL, libuv…) is never patched in-tree here. Needed fixes are
worked around via build flags/config where possible and recorded below
for upstreaming.

| Vendor | Issue | Status / workaround |
| --- | --- | --- |
| **Zen-C** | Importing the same C header (e.g. `"string.h"`) from two files is misreported as "Circular import detected" — the `.h` early-return in `src/parser/stmt/stmt_import.c` never removes the header from the `currently_parsing` cycle set. Regression after v0.4.4 (~300 commits); breaks ALL zapp builds on current Zen-C main, every platform. | ⚠️ **One-off local working-tree fix applied in `C:\Users\Zach\code\Zen-C` (uncommitted), made before the no-vendor-patches policy was set.** Needs upstreaming ASAP — until then, fresh Windows machines either apply the same 1-line fix (add `zmap_remove(&ctx->imports.currently_parsing, fn);` to the `.h` early-return branch) or pin a pre-regression zc. |
| **Zen-C** | `Map<void*>` instantiation also emits a phantom `MapEntry__void` struct containing `void val;` — invalid C, fails any backend compiler. Repro: `import "std/map.zc"; let m = Map<void*>::new();` → transpile. Regression vs the pre-0.4.4-300 zc macOS runs. | Worked around in zapp: `WindowManager.handles` is `Map<u64>` with casts at its 4 call sites (native/window/window.zc). Revert when fixed upstream. |
| **Zen-C** | `//>` link directives accumulate into a fixed `char link_flags[1024]` (src/compiler_config.h) with silent strncat truncation — long link lines lose characters mid-token (`-lwindowscodecs` → `lwindowscodecs`). | Worked around in zapp: on Windows the CLI writes the dynamic link set to `.zapp/zapp_link.rsp` and emits `//> link: @file` (gcc expands response files natively). Upstream: growable buffer + loud overflow error. |
| **Zen-C** | `@cfg(windows)` gates FUNCTIONS but not import emission — a `@cfg(windows) import "x.h"` still emits `#include "x.h"` into every platform's generated TU, so Windows headers collided with darwin types in macOS/iOS builds (ZappMenuItem). | Worked around in zapp: every `native/platform/windows/*.h` wraps its body in `#ifdef _WIN32` (inert on Windows). Upstream: respect `@cfg` for import emission. |
| **libuv 1.52.1** (via bare) | `src/win/util.c` trips `-Wincompatible-pointer-types`, an error on GCC ≥ 14. | Worked around: CLI passes `-DCMAKE_C_FLAGS=-Wno-error=incompatible-pointer-types` to the bare configure. Upstream fix wanted. |
| **BoringSSL** (via bare-tls/crypto) | fiat adx asm (`fiat_p256_adx_mul/sqr`) only assembles for ELF/Apple; MinGW COFF gets the C references but no definitions → link failure. | Worked around: `-DOPENSSL_NO_ASM=1` on Windows (pure-C crypto, slower EC only). Upstream: MinGW asm support. |
| **bare** | `bare_bin` (bare.exe) link fails under MinGW: `exports.def` demands `js_enable/disable_garbage_collection_tracking` (not defined by the QuickJS libjs backend) + the BoringSSL issue above. | Avoided: Windows builds `bare_static` (like iOS) — we never ship bare.exe. Module bindings come via the user-modules overlay. Upstream: libjs-quickjs GC-tracking stubs. |
| **zjs** | Windows entirely untested; libuv-path code-complete. Brotli embedded-asset decode uses Apple `compression_decode_buffer` only (possibly moot — WebView2 may serve `Content-Encoding: br` natively, unconfirmed). libuv vendoring story undefined. No Windows CI. | Out of scope this sprint (parallel session). CLI substitutes the default bare engine for `engine: "zjs"` on Windows (`substituteZjsOnWindows` in cli/src/config.ts) — remove when zjs lands. |

## Zen-C Docs

https://docs.zenc-lang.org/
