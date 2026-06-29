## Authoritative per-window route stack (N2a). Pure logic; the wire layer
## (router.nim) mutates it and emits ROUTE_CHANGED. Browser-history semantics:
## pop preserves forward; push truncates forward.
import std/tables

type
  RouteEntry = object
    url: string
    params: string          # JSON string; "" when none
  RouteState = object
    entries: seq[RouteEntry]
    cur: int

var gRoutes: Table[int32, RouteState]

proc routerSeed*(win: int32, url: string) =
  ## Establish the root entry (called once at window create). No-op if present.
  if not gRoutes.hasKey(win):
    gRoutes[win] = RouteState(entries: @[RouteEntry(url: url, params: "")], cur: 0)

proc routerClear*(win: int32) =
  gRoutes.del(win)

proc routerPush*(win: int32, url, params: string) =
  if not gRoutes.hasKey(win): routerSeed(win, "/")
  var s = gRoutes[win]
  s.entries.setLen(s.cur + 1)               # truncate forward
  s.entries.add RouteEntry(url: url, params: params)
  s.cur = s.entries.high
  gRoutes[win] = s

proc routerReplace*(win: int32, url, params: string) =
  if not gRoutes.hasKey(win): routerSeed(win, "/")
  var s = gRoutes[win]
  s.entries[s.cur] = RouteEntry(url: url, params: params)   # in place; forward preserved
  gRoutes[win] = s

proc routerPop*(win: int32): bool =
  if not gRoutes.hasKey(win): return false
  var s = gRoutes[win]
  if s.cur <= 0: return false
  s.cur.dec
  gRoutes[win] = s
  return true

proc routerForward*(win: int32): bool =
  if not gRoutes.hasKey(win): return false
  var s = gRoutes[win]
  if s.cur >= s.entries.high: return false
  s.cur.inc
  gRoutes[win] = s
  return true

proc routerPopToRoot*(win: int32): bool =
  if not gRoutes.hasKey(win): return false
  var s = gRoutes[win]
  if s.entries.len <= 1 and s.cur == 0: return false
  s.entries.setLen(1)
  s.cur = 0
  gRoutes[win] = s
  return true

proc routerCurrentUrl*(win: int32): string =
  if gRoutes.hasKey(win):
    let s = gRoutes[win]
    if s.entries.len > 0:
      return s.entries[s.cur].url
    else:
      return ""
  else:
    return ""

proc routerCurrentParams*(win: int32): string =
  if gRoutes.hasKey(win):
    let s = gRoutes[win]
    if s.entries.len > 0:
      return s.entries[s.cur].params
    else:
      return ""
  else:
    return ""

proc routerCanGoBack*(win: int32): bool =
  if gRoutes.hasKey(win):
    return gRoutes[win].cur > 0
  else:
    return false

proc routerCanGoForward*(win: int32): bool =
  if gRoutes.hasKey(win):
    let s = gRoutes[win]
    return s.cur < s.entries.high
  else:
    return false

# --- iOS native-routing read accessors (N3a). exportc so ios/routing.m importc's. ---
proc routerDepth*(win: int32): cint {.exportc: "router_depth", cdecl.} =
  ## Number of entries up to and including the current cursor (the native VC
  ## stack must match this: 1 = root only, N = root + (N-1) pushed routes).
  if gRoutes.hasKey(win):
    return (gRoutes[win].cur + 1).cint
  return 0

proc routerCurrentUrlC*(win: int32): cstring {.exportc: "router_current_url", cdecl.} =
  ## Top entry url for the iOS side (cstring view of the Nim string).
  ## Reuses routerCurrentUrl; "" when absent.
  return routerCurrentUrl(win).cstring
