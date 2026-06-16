## Worker registry — port of native/worker/registry.zc. POD + {.gcsafe.}: read
## (and supervisor counters written) from worker pthreads, so NO Nim GC — fixed
## array[N,char] buffers + libc string ops, the worker_service.nim/permissions.nim
## discipline. Lock-free (mirror the zc; main-thread add/remove, worker-thread
## single-writer supervisor counters).
##
## Thread discipline (registry.zc:16-20 in the plan):
##   - worker-thread READS: get_engine / get_display_name / list_json /
##     supervisor get_* — POD scans, no Nim heap.
##   - worker-thread WRITE (single-writer): record_failure increments the
##     crashing worker's OWN entry — no cross-entry contention.
##   - main-thread WRITES: add* / set_engine / remove / owner ops / set_policy
##     at create/terminate (the worker isn't racing its own entry then).
## Every exported proc is {.gcsafe.}; the compiler enforces it under --threads:on.

const
  ZAPP_MAX_WORKERS = 64
  ZAPP_MAX_OWNERS_PER_WORKER = 16

  # Engine selector ids — mirror registry.zc:19-24 EXACTLY. 0/1 were jsc/txiki
  # (removed); slots kept intact so serialised ids + the dispatch switch don't
  # renumber.
  ZAPP_ENGINE_BARE_JSC = 2
  ZAPP_ENGINE_BARE_V8 = 3
  ZAPP_ENGINE_BARE_QUICKJS = 4
  ZAPP_ENGINE_BARE_MQJS = 5
  ZAPP_ENGINE_BARE_HERMES = 6
  ZAPP_ENGINE_ZJS = 7

type
  ZappWorkerEntry = object
    workerId: array[64, char]
    name: array[64, char]          # display label; empty when unset
    scriptUrl: array[256, char]
    owners: array[ZAPP_MAX_OWNERS_PER_WORKER, array[64, char]]
    ownerCount: cint
    shared: cint                   # 0 = dedicated, 1 = shared
    active: cint
    engine: cint
    # --- Supervisor / restart policy ---
    restartMax: cint
    restartWindowMs: cint
    failCount: cint
    failWindowStartMs: int64
    gaveUp: cint

# Static registry — zero-initialised, exactly like registry.zc:48's `{{0}}`.
var gReg {.global.}: array[ZAPP_MAX_WORKERS, ZappWorkerEntry]

# --- libc (POD ops; gcsafe, no Nim GC) --------------------------------------
proc c_strncpy(dst: ptr char, src: cstring, n: csize_t): ptr char
  {.importc: "strncpy", header: "<string.h>", cdecl, discardable.}
proc c_strcpy(dst: ptr char, src: ptr char): ptr char
  {.importc: "strcpy", header: "<string.h>", cdecl, discardable.}
proc c_strcmp(a, b: cstring): cint {.importc: "strcmp", header: "<string.h>", cdecl.}
proc c_strlen(s: cstring): csize_t {.importc: "strlen", header: "<string.h>", cdecl.}
proc c_snprintf(buf: ptr char, n: csize_t, fmt: cstring): cint
  {.importc: "snprintf", header: "<stdio.h>", cdecl, varargs.}
proc c_sprintf(buf: ptr char, fmt: cstring): cint
  {.importc: "sprintf", header: "<stdio.h>", cdecl, varargs.}
proc c_malloc(n: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>", cdecl.}
proc c_realloc(p: pointer, n: csize_t): pointer
  {.importc: "realloc", header: "<stdlib.h>", cdecl.}
proc c_free*(p: pointer) {.importc: "free", header: "<stdlib.h>", cdecl.}

# Supervisor clock — mirror registry.zc:440-444 (gettimeofday → ms).
type Timeval {.importc: "struct timeval", header: "<sys/time.h>", bycopy.} = object
  tv_sec: clong
  tv_usec: clong
proc c_gettimeofday(tv: ptr Timeval, tz: pointer): cint
  {.importc: "gettimeofday", header: "<sys/time.h>", cdecl.}

proc supervisorNowMs(): int64 {.gcsafe.} =
  var tv: Timeval
  discard c_gettimeofday(addr tv, nil)
  int64(tv.tv_sec) * 1000'i64 + int64(tv.tv_usec) div 1000'i64

# --- Buffer helpers ----------------------------------------------------------
# Treat a fixed char array as a writable ptr char base + a readable cstring.
template bufBase(a: untyped): ptr char = addr a[0]
template bufStr(a: untyped): cstring = cast[cstring](addr a[0])

# --- Static helpers (registry.zc statics) -----------------------------------

# Add a dedicated worker (registry.zc:51-65). Returns slot index or -1.
proc registryAdd(workerId, ownerId: cstring): cint {.gcsafe.} =
  for i in 0 ..< ZAPP_MAX_WORKERS:
    if gReg[i].active == 0:
      c_strncpy(bufBase(gReg[i].workerId), workerId, 63)
      gReg[i].name[0] = '\0'
      c_strncpy(bufBase(gReg[i].owners[0]), ownerId, 63)
      gReg[i].ownerCount = 1
      gReg[i].shared = 0
      gReg[i].scriptUrl[0] = '\0'
      gReg[i].active = 1
      return cint(i)
  return -1

# Internal: return the index of an active entry by id, or -1.
proc registryIndex(workerId: cstring): int {.gcsafe.} =
  for i in 0 ..< ZAPP_MAX_WORKERS:
    if gReg[i].active != 0 and c_strcmp(bufStr(gReg[i].workerId), workerId) == 0:
      return i
  return -1

# --- C-ABI surface (exportc; names EXACT vs zjs.c externs) ------------------

# Add a worker with full options (registry.zc:71-103). Idempotent: a duplicate
# id is refreshed in place rather than double-allocated.
proc zapp_worker_registry_add_full_with_engine*(workerId, ownerId: cstring,
    shared: cint, scriptUrl: cstring, engine: cint): cint {.exportc, cdecl, gcsafe.} =
  # Update an existing entry if present.
  for i in 0 ..< ZAPP_MAX_WORKERS:
    if gReg[i].active != 0 and c_strcmp(bufStr(gReg[i].workerId), workerId) == 0:
      gReg[i].shared = shared
      gReg[i].engine = engine
      if scriptUrl != nil:
        c_strncpy(bufBase(gReg[i].scriptUrl), scriptUrl, 255)
        gReg[i].scriptUrl[255] = '\0'
      return cint(i)
  for i in 0 ..< ZAPP_MAX_WORKERS:
    if gReg[i].active == 0:
      c_strncpy(bufBase(gReg[i].workerId), workerId, 63)
      gReg[i].name[0] = '\0'
      c_strncpy(bufBase(gReg[i].owners[0]), ownerId, 63)
      gReg[i].ownerCount = 1
      gReg[i].shared = shared
      gReg[i].engine = engine
      if scriptUrl != nil:
        c_strncpy(bufBase(gReg[i].scriptUrl), scriptUrl, 255)
      else:
        gReg[i].scriptUrl[0] = '\0'
      gReg[i].active = 1
      return cint(i)
  return -1

# Backward-compat wrapper — engine defaults to -1 (registry.zc:107-110).
proc zapp_worker_registry_add_full*(workerId, ownerId: cstring,
    shared: cint, scriptUrl: cstring): cint {.exportc, cdecl, gcsafe.} =
  zapp_worker_registry_add_full_with_engine(workerId, ownerId, shared, scriptUrl, -1)

# Backward-compat dedicated add (registry.zc:51 made non-static for the C-ABI
# surface in the plan). Mirrors registryAdd.
proc zapp_worker_registry_add*(workerId, ownerId: cstring): cint
    {.exportc, cdecl, gcsafe.} =
  registryAdd(workerId, ownerId)

# As add_full_with_engine, but also records a display name (registry.zc:116-125).
# A non-empty name always wins; empty/NULL leaves the existing name untouched.
proc zapp_worker_registry_add_full_with_engine_and_name*(workerId, ownerId: cstring,
    shared: cint, scriptUrl: cstring, engine: cint, name: cstring): cint
    {.exportc, cdecl, gcsafe.} =
  let slot = zapp_worker_registry_add_full_with_engine(workerId, ownerId, shared, scriptUrl, engine)
  if slot >= 0 and name != nil and name[0] != '\0':
    c_strncpy(bufBase(gReg[slot].name), name, 63)
    gReg[slot].name[63] = '\0'
  return slot

# Backward-compat wrapper — engine -1 (registry.zc:129-133).
proc zapp_worker_registry_add_full_with_name*(workerId, ownerId: cstring,
    shared: cint, scriptUrl: cstring, name: cstring): cint
    {.exportc, cdecl, gcsafe.} =
  zapp_worker_registry_add_full_with_engine_and_name(workerId, ownerId, shared, scriptUrl, -1, name)

# Look up the engine for a worker; -1 if not found (registry.zc:136-144).
proc zapp_worker_registry_get_engine*(workerId: cstring): cint
    {.exportc, cdecl, gcsafe.} =
  let i = registryIndex(workerId)
  if i >= 0: gReg[i].engine else: -1

# Update the recorded engine (registry.zc:153-161).
proc zapp_worker_registry_set_engine*(workerId: cstring, engine: cint)
    {.exportc, cdecl, gcsafe.} =
  let i = registryIndex(workerId)
  if i >= 0: gReg[i].engine = engine

# Mark inactive (registry.zc:163-171).
proc zapp_worker_registry_remove*(workerId: cstring)
    {.exportc, cdecl, gcsafe.} =
  let i = registryIndex(workerId)
  if i >= 0: gReg[i].active = 0

# is_shared (registry.zc:186-194). 0 if not found.
proc zapp_worker_registry_is_shared*(workerId: cstring): cint
    {.exportc, cdecl, gcsafe.} =
  let i = registryIndex(workerId)
  if i >= 0: gReg[i].shared else: 0

# Find an existing shared worker by script URL (registry.zc:197-206). Returns
# the worker_id (a pointer into the static entry) or nil. registry.zc keeps this
# `static`; the plan exports it as a Nim proc (no exportc) for B7b's router path.
proc registryFindShared*(scriptUrl: cstring): cstring {.gcsafe.} =
  if scriptUrl == nil: return nil
  for i in 0 ..< ZAPP_MAX_WORKERS:
    if gReg[i].active != 0 and gReg[i].shared != 0 and
        c_strcmp(bufStr(gReg[i].scriptUrl), scriptUrl) == 0:
      return bufStr(gReg[i].workerId)
  return nil

# Add an owner to a shared worker (registry.zc:209-225). 0 ok, -1 not found/full.
# `static` in the zc; exported as a Nim proc (no exportc) for B7b's router path.
proc registryAddOwner*(workerId, ownerId: cstring): cint {.gcsafe.} =
  for i in 0 ..< ZAPP_MAX_WORKERS:
    if gReg[i].active != 0 and c_strcmp(bufStr(gReg[i].workerId), workerId) == 0:
      let c = gReg[i].ownerCount
      for j in 0 ..< c:
        if c_strcmp(bufStr(gReg[i].owners[j]), ownerId) == 0: return 0
      if c >= ZAPP_MAX_OWNERS_PER_WORKER: return -1
      c_strncpy(bufBase(gReg[i].owners[c]), ownerId, 63)
      inc gReg[i].ownerCount
      return 0
  return -1

# Remove an owner (registry.zc:228-247). Returns remaining count, or -1 if not
# found.
proc zapp_worker_registry_remove_owner*(workerId, ownerId: cstring): cint
    {.exportc, cdecl, gcsafe.} =
  for i in 0 ..< ZAPP_MAX_WORKERS:
    if gReg[i].active != 0 and c_strcmp(bufStr(gReg[i].workerId), workerId) == 0:
      for j in 0 ..< gReg[i].ownerCount:
        if c_strcmp(bufStr(gReg[i].owners[j]), ownerId) == 0:
          # Shift remaining owners down.
          for k in j ..< gReg[i].ownerCount - 1:
            c_strcpy(bufBase(gReg[i].owners[k]), bufBase(gReg[i].owners[k + 1]))
          dec gReg[i].ownerCount
          return gReg[i].ownerCount
      return gReg[i].ownerCount
  return -1

# Display label: configured name if set, else worker_id (registry.zc:264-270).
# "" for NULL id; falls back to the passed-in id when unregistered.
proc zapp_worker_registry_get_display_name*(workerId: cstring): cstring
    {.exportc, cdecl, gcsafe.} =
  if workerId == nil: return cstring""
  let i = registryIndex(workerId)
  if i < 0: return workerId
  if gReg[i].name[0] != '\0': return bufStr(gReg[i].name)
  return bufStr(gReg[i].workerId)

# Compact a ms duration for logs (registry.zc:274-285). Static buffer.
var gFmtBuf {.global.}: array[32, char]
proc zapp_fmt_compact_ms*(ms: cint): cstring {.exportc, cdecl, gcsafe.} =
  if ms < 1000:
    discard c_snprintf(bufBase(gFmtBuf), 32, cstring"%dms", ms)
  else:
    let s = ms div 1000
    let frac = (ms mod 1000) div 100
    if frac == 0:
      discard c_snprintf(bufBase(gFmtBuf), 32, cstring"%ds", s)
    else:
      discard c_snprintf(bufBase(gFmtBuf), 32, cstring"%d.%ds", s, frac)
  bufStr(gFmtBuf)

# --- list_json (registry.zc:287-429) ----------------------------------------

# JSON double-quote escape into a fresh malloc'd buffer (registry.zc:292-315).
# Returns nil on OOM. Caller frees.
proc jsonEscapeDup(s: cstring): cstring {.gcsafe.} =
  var src = s
  if src == nil: src = cstring""
  let len = c_strlen(src)
  let outp = cast[ptr UncheckedArray[char]](c_malloc(len * 6 + 1))  # worst case \u00xx
  if outp == nil: return nil
  var o: csize_t = 0
  var i: csize_t = 0
  while i < len:
    let c = cast[uint8](src[i])
    case c
    of uint8(ord('"')): outp[o] = '\\'; inc o; outp[o] = '"'; inc o
    of uint8(ord('\\')): outp[o] = '\\'; inc o; outp[o] = '\\'; inc o
    of 0x08'u8: outp[o] = '\\'; inc o; outp[o] = 'b'; inc o   # \b
    of 0x0c'u8: outp[o] = '\\'; inc o; outp[o] = 'f'; inc o   # \f
    of 0x0a'u8: outp[o] = '\\'; inc o; outp[o] = 'n'; inc o   # \n
    of 0x0d'u8: outp[o] = '\\'; inc o; outp[o] = 'r'; inc o   # \r
    of 0x09'u8: outp[o] = '\\'; inc o; outp[o] = 't'; inc o   # \t
    else:
      if c < 0x20'u8:
        o += csize_t(c_sprintf(addr outp[o], cstring"\\u%04x", cint(c)))
      else:
        outp[o] = cast[char](c); inc o
    inc i
  outp[o] = '\0'
  return cast[cstring](outp)

# Grow-on-truncation append (registry.zc:325-340). The zc's zapp_json_append is
# a vsnprintf-driven varargs helper; Nim can neither forward a Nim `varargs` into
# a C varargs importc nor relay a va_list, so this port splits it: jsonAppendStr
# appends an already-rendered cstring (growing the buffer to fit — preserving the
# zc's unbounded-growth guarantee, since the escaped worker_id/name/url/owner
# strings are the only unbounded fragments and they arrive pre-rendered), and the
# one integer-bearing fragment (supervisor) is rendered with c_snprintf into a
# bounded local scratch (4 ints + fixed template ≪ scratch) then appended. The
# resulting JSON bytes are byte-identical to the zc's.
# Returns 0 ok, -1 on alloc failure.
proc jsonAppendStr(buf: var cstring, cap, off: var csize_t, s: cstring): cint
    {.gcsafe.} =
  let slen = c_strlen(s)
  let need = off + slen + 1
  if need > cap:
    var newcap: csize_t = (if cap != 0: cap else: 256)
    while newcap < need: newcap *= 2
    let nb = c_realloc(buf, newcap)
    if nb == nil: return -1
    buf = cast[cstring](nb)
    cap = newcap
  # strcpy into the tail (need accounts for the NUL).
  c_strcpy(cast[ptr char](cast[uint](buf) + uint(off)), cast[ptr char](s))
  off += slen
  return 0

# Engine id → label, "pending" for unknown / resolver-default -1
# (registry.zc:360-368).
proc engineStr(engine: cint): cstring {.gcsafe.} =
  case engine
  of ZAPP_ENGINE_ZJS: cstring"zjs"
  of ZAPP_ENGINE_BARE_JSC: cstring"bare-jsc"
  of ZAPP_ENGINE_BARE_V8: cstring"bare-v8"
  of ZAPP_ENGINE_BARE_QUICKJS: cstring"bare-quickjs"
  of ZAPP_ENGINE_BARE_MQJS: cstring"bare-mqjs"
  of ZAPP_ENGINE_BARE_HERMES: cstring"bare-hermes"
  else: cstring"pending"

# Fixed JSON-literal fragments. Bound to named consts because a string literal
# with \" escapes spliced inline elsewhere can trip the Nim parser; a const ref
# does not. These are byte-identical to the zc's format strings (sans the %s/%d
# placeholders, which are filled by jsonAppendStr of the rendered piece).
const
  fmtOpen = cstring"["
  fmtClose = cstring"]"
  fmtCloseObj = cstring"}"
  fmtComma = cstring","
  fmtEmpty = cstring""
  litObjId = cstring("{\"id\":\"")           # → {"id":"<eid>
  litNameKey = cstring("\",\"name\":\"")     # close id quote → ,"name":"<ename>
  litUrlKey = cstring("\",\"scriptUrl\":\"") # close prev quote → ,"scriptUrl":"<eurl>
  litEngineKey = cstring("\",\"engine\":\"") # close url quote → ,"engine":"<estr>
  litSharedKey = cstring("\",\"shared\":")   # close engine quote → ,"shared":
  litOwnersKey = cstring(",\"owners\":[")
  litQuote = cstring("\"")
  # supervisor fragment carries 4 ints — rendered via c_snprintf into a bounded
  # scratch (matches registry.zc:417-420 exactly).
  fmtSupervisor = cstring(",\"supervisor\":{\"maxRetries\":%d,\"withinMs\":%d,\"failCount\":%d,\"gaveUp\":%s}")

# Heap JSON array of all ACTIVE workers (registry.zc:345-429). Caller free()s.
# Built so the bytes are identical to the zc: each {"id":"<id>"[,"name":"<n>"],
# "scriptUrl":"<u>","engine":"<e>","shared":<b>,"owners":[<o>,...]
# [,"supervisor":{...}]}.
proc zapp_workers_registry_list_json*(): cstring {.exportc, cdecl, gcsafe.} =
  var cap: csize_t = 1024
  var off: csize_t = 0
  var buf = cast[cstring](c_malloc(cap))
  if buf == nil: return nil
  buf[0] = '\0'
  template ap(s: cstring): untyped =
    if jsonAppendStr(buf, cap, off, s) < 0: c_free(buf); return nil
  if jsonAppendStr(buf, cap, off, fmtOpen) < 0: c_free(buf); return nil
  var first = 1
  for i in 0 ..< ZAPP_MAX_WORKERS:
    if gReg[i].active == 0: continue
    let estr = engineStr(gReg[i].engine)

    let eid = jsonEscapeDup(bufStr(gReg[i].workerId))
    if eid == nil: c_free(buf); return nil
    if jsonAppendStr(buf, cap, off, (if first != 0: fmtEmpty else: fmtComma)) < 0:
      c_free(eid); c_free(buf); return nil
    if jsonAppendStr(buf, cap, off, litObjId) < 0: c_free(eid); c_free(buf); return nil
    if jsonAppendStr(buf, cap, off, eid) < 0: c_free(eid); c_free(buf); return nil
    c_free(eid)

    if gReg[i].name[0] != '\0':
      let ename = jsonEscapeDup(bufStr(gReg[i].name))
      if ename == nil: c_free(buf); return nil
      # NB: ename is live here — the bare `ap` template only frees buf, so free
      # ename too on the append-failure (realloc-OOM) path (zc:384 freed it).
      if jsonAppendStr(buf, cap, off, litNameKey) < 0: c_free(ename); c_free(buf); return nil
      if jsonAppendStr(buf, cap, off, ename) < 0: c_free(ename); c_free(buf); return nil
      c_free(ename)
      ap(litUrlKey)             # closes the name quote, opens "scriptUrl":"
    else:
      ap(litUrlKey)             # closes the id quote, opens "scriptUrl":"

    let eurl = jsonEscapeDup(bufStr(gReg[i].scriptUrl))
    if eurl == nil: c_free(buf); return nil
    if jsonAppendStr(buf, cap, off, eurl) < 0: c_free(eurl); c_free(buf); return nil
    c_free(eurl)
    ap(litEngineKey)            # closes url quote, opens "engine":"
    ap(estr)
    ap(litSharedKey)            # closes engine quote, opens "shared":
    ap(if gReg[i].shared != 0: cstring"true" else: cstring"false")
    ap(litOwnersKey)

    # Skip empty owner slots (headless workers register owner "") so the payload
    # reports owners:[] not owners:[""] (registry.zc:403-413).
    var firstOwner = 1
    for o in 0 ..< gReg[i].ownerCount:
      if gReg[i].owners[o][0] == '\0': continue
      let eowner = jsonEscapeDup(bufStr(gReg[i].owners[o]))
      if eowner == nil: c_free(buf); return nil
      if jsonAppendStr(buf, cap, off, (if firstOwner != 0: fmtEmpty else: fmtComma)) < 0:
        c_free(eowner); c_free(buf); return nil
      if jsonAppendStr(buf, cap, off, litQuote) < 0: c_free(eowner); c_free(buf); return nil
      if jsonAppendStr(buf, cap, off, eowner) < 0: c_free(eowner); c_free(buf); return nil
      if jsonAppendStr(buf, cap, off, litQuote) < 0: c_free(eowner); c_free(buf); return nil
      c_free(eowner)
      firstOwner = 0
    ap(fmtClose)                # close owners array

    if gReg[i].restartMax > 0:
      var scratch: array[160, char]
      discard c_snprintf(bufBase(scratch), 160, fmtSupervisor,
          gReg[i].restartMax, gReg[i].restartWindowMs, gReg[i].failCount,
          (if gReg[i].gaveUp != 0: cstring"true" else: cstring"false"))
      ap(bufStr(scratch))
    ap(fmtCloseObj)
    first = 0
  if jsonAppendStr(buf, cap, off, fmtClose) < 0: c_free(buf); return nil
  return buf

# --- Supervisor public API (registry.zc:431-516) ----------------------------

# Configure the restart policy (registry.zc:449-457). max==0 disables.
proc zapp_worker_supervisor_set_policy*(workerId: cstring, max, windowMs: cint)
    {.exportc, cdecl, gcsafe.} =
  let i = registryIndex(workerId)
  if i < 0: return
  gReg[i].restartMax = max
  gReg[i].restartWindowMs = if windowMs > 0: windowMs else: 60000
  gReg[i].failCount = 0
  gReg[i].failWindowStartMs = 0
  gReg[i].gaveUp = 0

# Record a worker failure (registry.zc:469-488).
#   0 — ignore (no policy); 1 — restart approved; 2 — gave up (sticks).
proc zapp_worker_supervisor_record_failure*(workerId: cstring): cint
    {.exportc, cdecl, gcsafe.} =
  let i = registryIndex(workerId)
  if i < 0: return 0
  if gReg[i].restartMax <= 0: return 0
  if gReg[i].gaveUp != 0: return 2

  let now = supervisorNowMs()
  if gReg[i].failCount == 0 or
      (now - gReg[i].failWindowStartMs) > int64(gReg[i].restartWindowMs):
    gReg[i].failCount = 1
    gReg[i].failWindowStartMs = now
    return 1
  inc gReg[i].failCount
  if gReg[i].failCount > gReg[i].restartMax:
    gReg[i].gaveUp = 1
    return 2
  return 1

# Helpers the engine needs to recreate a worker on restart (registry.zc:491-499).
proc zapp_worker_supervisor_get_script_url*(workerId: cstring): cstring
    {.exportc, cdecl, gcsafe.} =
  let i = registryIndex(workerId)
  if i < 0: return nil
  bufStr(gReg[i].scriptUrl)

proc zapp_worker_supervisor_get_owner*(workerId: cstring): cstring
    {.exportc, cdecl, gcsafe.} =
  let i = registryIndex(workerId)
  if i < 0 or gReg[i].ownerCount == 0: return cstring""
  bufStr(gReg[i].owners[0])

# Read-only window-state inspection (registry.zc:504-516). 0 ok, -1 if missing.
proc zapp_worker_supervisor_get_window_state*(workerId: cstring,
    outCount, outCap, outWindowMs: ptr cint): cint {.exportc, cdecl, gcsafe.} =
  let i = registryIndex(workerId)
  if i < 0: return -1
  if outCount != nil: outCount[] = gReg[i].failCount
  if outCap != nil: outCap[] = gReg[i].restartMax
  if outWindowMs != nil: outWindowMs[] = gReg[i].restartWindowMs
  return 0
