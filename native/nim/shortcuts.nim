## Global shortcuts (Carbon hotkeys) — webview surface. Mirrors the zc
## router_handle_shortcuts (which wraps Shortcuts:: → darwin_shortcut_*).
## MAIN-THREAD (webview->native); idiomatic. The hotkey-press EVENT is fired
## by shortcuts.m via zapp_app_dispatch (app_events.nim) — no Nim wiring here.
##
## NB: darwin_shortcut_* are defined in native/platform/darwin/shortcuts.m,
## compiled by the build root (zapp.nim, which also links -framework Carbon).

proc darwin_shortcut_register(accelerator: cstring): bool {.importc, cdecl.}
proc darwin_shortcut_unregister(accelerator: cstring): bool {.importc, cdecl.}
proc darwin_shortcut_is_registered(accelerator: cstring): bool {.importc, cdecl.}
proc darwin_shortcut_unregister_all() {.importc, cdecl.}

proc shortcutRegister*(accelerator: string): bool = darwin_shortcut_register(accelerator.cstring)
proc shortcutUnregister*(accelerator: string): bool = darwin_shortcut_unregister(accelerator.cstring)
proc shortcutIsRegistered*(accelerator: string): bool = darwin_shortcut_is_registered(accelerator.cstring)
proc shortcutUnregisterAll*() = darwin_shortcut_unregister_all()
