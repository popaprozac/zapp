## Global shortcuts (Carbon hotkeys) — webview surface. Mirrors the zc
## router_handle_shortcuts (which wraps Shortcuts:: → darwin_shortcut_*).
## MAIN-THREAD (webview->native); idiomatic. The hotkey-press EVENT is fired
## by shortcuts.m via zapp_app_dispatch (app_events.nim) — no Nim wiring here.
##
## NB: darwin_shortcut_* are defined in native/platform/darwin/shortcuts.m,
## compiled by the build root (zapp.nim, which also links -framework Carbon).

import nativeabi
proc nativeShortcutRegister(accelerator: cstring): bool {.importc: abiPrefix & "shortcut_register", cdecl.}
proc nativeShortcutUnregister(accelerator: cstring): bool {.importc: abiPrefix & "shortcut_unregister", cdecl.}
proc nativeShortcutIsRegistered(accelerator: cstring): bool {.importc: abiPrefix & "shortcut_is_registered", cdecl.}
proc nativeShortcutUnregisterAll() {.importc: abiPrefix & "shortcut_unregister_all", cdecl.}

proc shortcutRegister*(accelerator: string): bool = nativeShortcutRegister(accelerator.cstring)
proc shortcutUnregister*(accelerator: string): bool = nativeShortcutUnregister(accelerator.cstring)
proc shortcutIsRegistered*(accelerator: string): bool = nativeShortcutIsRegistered(accelerator.cstring)
proc shortcutUnregisterAll*() = nativeShortcutUnregisterAll()
