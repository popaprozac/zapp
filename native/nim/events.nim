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

## EventResult: zapp_dispatch_event's return contract (events.zc enum EventResult).
## 0 = ALLOW (proceed), 1 = CANCEL (stop the native action).
const EVENT_ALLOW* = 0
const EVENT_CANCEL* = 1
