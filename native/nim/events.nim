## Window + app event codes. Values MUST match native/window/events.zc exactly
## (the .m layer passes these integers as plain ints). Used by callbacks.nim and,
## later, app_events.nim. Confirmed against native/window/events.zc:
##   window 0..11, app 100..108, ZAPP_MAX_WINDOW_EVENT_TYPES == 12 (events.zc:95).
## ZAPP_MAX_WINDOW_CALLBACKS == 64 (callbacks.zc:11, the registry size).

const
  ZAPP_MAX_WINDOW_CALLBACKS* = 64
  ZAPP_MAX_WINDOW_EVENT_TYPES* = 12

type
  WindowEvent* = enum
    weReady = 0, weFocus = 1, weBlur = 2, weResize = 3, weMove = 4, weClose = 5,
    weMinimize = 6, weMaximize = 7, weRestore = 8, weFullscreen = 9,
    weUnfullscreen = 10, weModalDismissed = 11
  AppEvent* = enum
    aeStarted = 100, aeShutdown = 101, aeNotificationClick = 102,
    aeNotificationAction = 103, aeReopen = 104, aeOpenUrl = 105,
    aeDidBecomeActive = 106, aeDidResignActive = 107, aeThemeChanged = 108

## zapp_dispatch_event's return contract now lives in coretypes.nim as the
## `EventResult` {.pure.} enum (Allow/Cancel) — see callbacks.nim.

import std/strutils

proc eventNameToId*(name: string): int =
  ## Map a `window:eventname` (or bare `eventname`) subscription string to the
  ## window-event bitmask id. Source of truth: native/app/router.zc:355-374
  ## (event_name_to_id) — strip the "window:" prefix, then ready=0..unfullscreen=10.
  ## Returns -1 for an unknown name. Kept here (the pure events module, no importc
  ## deps) so it's unit-testable without linking platform symbols.
  var n = name
  if n.startsWith("window:"): n = n[7 .. ^1]
  case n
  of "ready": 0
  of "focus": 1
  of "blur": 2
  of "resize": 3
  of "move": 4
  of "close": 5
  of "minimize": 6
  of "maximize": 7
  of "restore": 8
  of "fullscreen": 9
  of "unfullscreen": 10
  # Sidebar/inspector chrome events (ids 12-19) are intentionally NOT mapped
  # here: they're delivered directly via zapp_pane_emit -> dispatchWindowEvent
  # in the webview bridge, bypassing the gJsListeners bitmask. Mapping them
  # would route delivery through the bitmask and silently drop them. See #627.
  else: -1
