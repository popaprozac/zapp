# Windows Porting Guide

State of the Windows port and the handoff brief for the Windows parity
sprint (task #167 / competitive-plan T2.C). Updated 2026-06-11, immediately
after the macOS native-chrome trilogy (sidebars, toolbars, popovers) merged
— this doc is written to seed a brainstorming session on a Windows machine.

macOS is the reference platform with full coverage; iOS shares most of the
Zen-C layer. Windows has v1-era scaffolding whose functional state is
**UNVERIFIED against current main** — treat every "works" claim below as
"worked in the v1 port" until re-proven. **The first task on a PC is a
build + runtime inventory: `bun run build --platform windows` in
hello-world, fix until it compiles/links, then catalog what actually
functions.**

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

## Zen-C Docs

https://docs.zenc-lang.org/
