## Native permissions — manifest parser + verb-semantics check + the
## invoke→permission-id mapping. Ported from native/permissions/permissions.zc
## and permission_id_for_invoke from native/app/router.zc.
##
## WORKER-THREAD DISCIPLINE (load-bearing): permissions_check /
## permissionsIsAllowed / permission_id_for_invoke run on the zjs/bare worker
## pthread (zjs.c / bare.c) as well as the Cocoa main thread. So the CHECK path
## is {.gcsafe.} and touches ONLY POD state (cstring arrays, ints) — no Nim heap,
## no ORC — exactly like worker_service.nim. The PARSE (std/json) runs ONLY at
## main-thread eager-init (app.nim run() calls permissionsEnsureInit before any
## window/worker exists), so it never runs on a worker thread. The check path
## never calls the parser — that is what keeps {.gcsafe.} sound.
## INVARIANT: permissions must be initialized before the first check; an
## un-init'd check reads gActive=false => allow-all (fail-open), matching the
## no-manifest contract. permission_id_for_invoke lives here (not router.nim) for
## the same reason eventNameToId lives in events.nim: pure + unit-testable.
import std/json

proc zapp_build_permissions_json(): cstring {.importc, cdecl.}

# libc (POD ops; safe on the worker check path)
proc c_strdup(s: cstring): cstring {.importc: "strdup", header: "<string.h>", cdecl.}
proc c_strcmp(a, b: cstring): cint {.importc: "strcmp", header: "<string.h>", cdecl.}
proc c_strncmp(a, b: cstring, n: csize_t): cint {.importc: "strncmp", header: "<string.h>", cdecl.}
proc c_strlen(s: cstring): csize_t {.importc: "strlen", header: "<string.h>", cdecl.}
proc c_strchr(s: cstring, ch: cint): cstring {.importc: "strchr", header: "<string.h>", cdecl.}
proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>", cdecl.}
proc c_fprintf(stream: pointer, fmt: cstring) {.importc: "fprintf", varargs, header: "<stdio.h>", cdecl.}
var cstderr {.importc: "stderr", header: "<stdio.h>".}: pointer

const MAXP = 64
var gLoaded = false
var gActive = false
var gAllow: array[MAXP, cstring]
var gAllowCount = 0
var gLogged: array[MAXP, cstring]
var gLoggedCount = 0

proc permissionsResetAndLoad*(json: string) =
  ## Reset state and (re)parse `json` (std/json; main-thread / test seam).
  ## Parse error or absent/false `active` => stays inactive (fail-open).
  for i in 0 ..< gAllowCount:
    c_free(gAllow[i]); gAllow[i] = nil
  gAllowCount = 0
  for i in 0 ..< gLoggedCount:
    c_free(gLogged[i]); gLogged[i] = nil
  gLoggedCount = 0
  gActive = false
  gLoaded = true
  var root: JsonNode
  try:
    root = parseJson(json)
  except CatchableError:
    return                       # unparseable => inactive (fail-open)
  if root.kind != JObject: return
  if root{"active"}.getBool(false):
    gActive = true
    let allow = root{"allow"}
    if not allow.isNil and allow.kind == JArray:
      for elem in allow:
        if elem.kind == JString and gAllowCount < MAXP:
          gAllow[gAllowCount] = c_strdup(elem.getStr().cstring)
          inc gAllowCount

proc permissionsEnsureInit*() =
  ## Lazy guard; eager-called from app.nim boot (main thread).
  if gLoaded: return
  permissionsResetAndLoad($zapp_build_permissions_json())

proc permissionsIsAllowed*(id: cstring): bool {.gcsafe.} =
  ## POD reader (worker-safe). Does NOT init — relies on eager-init.
  if not gActive: return true
  if id.isNil or id[0] == '\0': return false
  for i in 0 ..< gAllowCount:
    if c_strcmp(id, gAllow[i]) == 0: return true
  let colon = c_strchr(id, ord(':').cint)
  if not colon.isNil:
    let mlen = cast[csize_t](cast[uint](colon) - cast[uint](id))
    if mlen > 0:
      for i in 0 ..< gAllowCount:
        if c_strlen(gAllow[i]) == mlen and c_strncmp(id, gAllow[i], mlen) == 0:
          return true
  return false

proc permissions_check*(id: cstring, meth: cstring): bool {.exportc, cdecl, gcsafe.} =
  ## Gate `id` for `meth`. Allowed => true; denied => one-shot stderr log + false.
  if permissionsIsAllowed(id): return true
  var seen = false
  for i in 0 ..< gLoggedCount:
    if c_strcmp(id, gLogged[i]) == 0:
      seen = true; break
  if not seen and gLoggedCount < MAXP:
    gLogged[gLoggedCount] = c_strdup(id); inc gLoggedCount
    c_fprintf(cstderr,
      cstring("[zapp] permission denied: %s (%s) — add \"%s\" to permissions in zapp.config.ts\n"),
      id, meth, id)
  return false

proc permissions_bootstrap_json*(): cstring {.exportc, cdecl.} =
  ## Raw manifest JSON (webview.m injects it; the router __zapp:permissions route
  ## forwards it — that route is Batch 5).
  zapp_build_permissions_json()

proc permission_id_for_invoke*(meth: cstring): cstring {.exportc, cdecl, gcsafe.} =
  ## Map a t:1 invoke method to a permission id ("" = ungated). Pure cstring
  ## logic; mirrors router.zc:21-36. String literals returned as cstring are
  ## static storage (stable). zjs.c / bare.c call this via extern.
  if c_strncmp(meth, cstring"__clipboard:", 12) == 0:
    let rest = cast[cstring](cast[uint](meth) + 12)
    if c_strncmp(rest, cstring"read", 4) == 0: return cstring"clipboard:read"
    if c_strncmp(rest, cstring"has", 3) == 0: return cstring"clipboard:read"
    return cstring"clipboard:write"
  if c_strncmp(meth, cstring"__dialog:", 9) == 0: return cstring"dialog"
  if c_strncmp(meth, cstring"__notif:", 8) == 0: return cstring"notifications"
  if c_strncmp(meth, cstring"__shortcuts:", 12) == 0: return cstring"shortcuts"
  if c_strncmp(meth, cstring"__screen:", 9) == 0: return cstring"screen"
  if c_strcmp(meth, cstring"__window:create") == 0: return cstring"window:create"
  return cstring""

proc permission_id_for_action*(action: cstring): cstring =
  ## Map a t:4 fire-and-forget action to a permission id ("" = ungated: window
  ## ops, app lifecycle, plumbing). Pure cstring logic; mirrors router.zc:40-54.
  ## Router-internal (no worker-engine caller) → plain exported Nim proc, no
  ## exportc. String literals returned as cstring are static storage.
  if c_strncmp(action, cstring"tray:", 5) == 0: return cstring"tray"
  if c_strncmp(action, cstring"dock:", 5) == 0: return cstring"dock"
  if c_strcmp(action, cstring"panelCreate") == 0 or
     c_strcmp(action, cstring"panelSetBounds") == 0 or
     c_strcmp(action, cstring"panelLoadUrl") == 0 or
     c_strcmp(action, cstring"panelExecJs") == 0 or
     c_strcmp(action, cstring"panelPostMessage") == 0 or
     c_strcmp(action, cstring"panelShow") == 0 or
     c_strcmp(action, cstring"panelHide") == 0 or
     c_strcmp(action, cstring"panelReload") == 0 or
     c_strcmp(action, cstring"panelBack") == 0 or
     c_strcmp(action, cstring"panelForward") == 0 or
     c_strcmp(action, cstring"panelDestroy") == 0: return cstring"embed"
  if c_strcmp(action, cstring"setMenu") == 0: return cstring"menu"
  if c_strcmp(action, cstring"showContextMenu") == 0: return cstring"menu"
  if c_strcmp(action, cstring"openExternal") == 0: return cstring"shell:open"
  if c_strcmp(action, cstring"openPath") == 0: return cstring"shell:open"
  if c_strcmp(action, cstring"showItemInFolder") == 0: return cstring"shell:reveal"
  if c_strcmp(action, cstring"trashItem") == 0: return cstring"shell:trash"
  return cstring""
