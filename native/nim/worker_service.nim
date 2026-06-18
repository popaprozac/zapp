## Worker-path service dispatch. service_invoke_native is the C-ABI seam zjs.c
## calls ON THE WORKER PTHREAD. Dispatches to the REAL Nim service registry via
## a POD snapshot (gSnap) built once on the MAIN thread at boot and read-only
## thereafter — no cross-heap Nim seq reads on the worker, no alloc in the
## lookup loop.
##
## Foreign-thread GC is set up by zapp_worker_thread_gc_init (exported here),
## called by zjs.c once per worker pthread before its message loop; without it,
## any Nim alloc on the worker would be UB under ORC.
import std/json
import apptypes        # App, AppServiceHandler
import service         # registeredServices

# ---------------------------------------------------------------------------
# JsonValue C-ABI mirror (Task 4: JsonValue* → JsonNode walker)
#
# The provider (.zapp/zjson_provider.o, linked via --passL) exports the full
# JsonValue type and accessor functions.  We emit the struct layout as a Nim
# {.emit.} header fragment so the Nim-generated C sees the declarations, then
# importc the accessor functions from zjson_provider.o.
#
# Exact C layout (from .zapp/zjson_provider.c):
#   typedef enum { JSON_NULL=0, JSON_BOOL=1, JSON_NUMBER=2,
#                  JSON_STRING=3, JSON_ARRAY=4, JSON_OBJECT=5 } JsonType;
#   struct JsonValue { JsonType kind; char* string_val; double number_val;
#                      bool bool_val; Vec__JsonValuePtr* array_val;
#                      Map__JsonValuePtr* object_val; };
#   struct Vec__JsonValuePtr { JsonValue** data; size_t len; size_t cap; };
#   struct Map__JsonValuePtr { char** keys; JsonValue** vals;
#                              bool* occupied; bool* deleted;
#                              size_t len; size_t cap; };
# ---------------------------------------------------------------------------

# NOTE: the {.emit.} block below crosses this module's "no {.emit.}" boundary
# as a workaround — the provider (.zapp/zjson_provider.o) ships with no header,
# so we inline the struct layout here.  Tracked follow-up: once the provider
# build emits a header, convert to {.importc, header: "zjson_provider.h".}.
{.emit: """
#include <stddef.h>
#include <stdbool.h>
typedef enum {
    JsonType__JSON_NULL_Tag   = 0,
    JsonType__JSON_BOOL_Tag   = 1,
    JsonType__JSON_NUMBER_Tag = 2,
    JsonType__JSON_STRING_Tag = 3,
    JsonType__JSON_ARRAY_Tag  = 4,
    JsonType__JSON_OBJECT_Tag = 5
} JsonType;
typedef struct JsonValue JsonValue;
typedef struct {
    JsonValue** data;
    size_t len;
    size_t cap;
} Vec__JsonValuePtr;
typedef struct {
    char**     keys;
    JsonValue** vals;
    bool*      occupied;
    bool*      deleted;
    size_t     len;
    size_t     cap;
} Map__JsonValuePtr;
struct JsonValue {
    JsonType         kind;
    char*            string_val;
    double           number_val;
    bool             bool_val;
    Vec__JsonValuePtr*  array_val;
    Map__JsonValuePtr*  object_val;
};
""".}

const
  JSON_KIND_NULL   = 0.cint
  JSON_KIND_BOOL   = 1.cint
  JSON_KIND_NUMBER = 2.cint
  JSON_KIND_STRING = 3.cint
  JSON_KIND_ARRAY  = 4.cint
  JSON_KIND_OBJECT = 5.cint

# Opaque Nim types — used only as pointer targets; layout comes from the emit above.
type
  CJsonValue  {.importc: "struct JsonValue",      nodecl.} = object
  CVecJVPtr   {.importc: "Vec__JsonValuePtr",      nodecl.} = object
  CMapJVPtr   {.importc: "Map__JsonValuePtr",      nodecl.} = object

# The full struct mirror for field-level access (bycopy = pass by value not ptr).
type CJsonValueS {.importc: "struct JsonValue", bycopy, nodecl.} = object
  kind:        cint
  string_val:  cstring
  number_val:  cdouble
  bool_val:    bool
  array_val:   ptr CVecJVPtr
  object_val:  ptr CMapJVPtr

# Vec__JsonValuePtr accessors (from zjson_provider.o)
proc vecJVLen(v: ptr CVecJVPtr): csize_t
    {.importc: "Vec__JsonValuePtr__length", cdecl.}
proc vecJVGet(v: ptr CVecJVPtr; idx: csize_t): ptr CJsonValue
    {.importc: "Vec__JsonValuePtr__get", cdecl.}

# Map__JsonValuePtr accessors (from zjson_provider.o)
proc mapJVCap(m: ptr CMapJVPtr): csize_t
    {.importc: "Map__JsonValuePtr__capacity", cdecl.}
proc mapJVOccupied(m: ptr CMapJVPtr; idx: csize_t): bool
    {.importc: "Map__JsonValuePtr__is_slot_occupied", cdecl.}
proc mapJVKeyAt(m: ptr CMapJVPtr; idx: csize_t): cstring
    {.importc: "Map__JsonValuePtr__key_at", cdecl.}
proc mapJVValAt(m: ptr CMapJVPtr; idx: csize_t): ptr CJsonValue
    {.importc: "Map__JsonValuePtr__val_at", cdecl.}

proc jsonValueToNode*(p: pointer): JsonNode =
  ## Walk a C JsonValue* (from zjson_provider.o) into a Nim JsonNode.
  ## Allocates on the current thread's heap (foreign-thread GC already set up
  ## by zapp_worker_thread_gc_init before this is ever called).
  ## nil pointer → JNull (covers the "no args" case).
  if p == nil:
    return newJNull()
  let jv = cast[ptr CJsonValueS](p)
  case jv.kind
  of JSON_KIND_NULL:
    result = newJNull()
  of JSON_KIND_BOOL:
    result = newJBool(jv.bool_val)
  of JSON_KIND_NUMBER:
    let d = jv.number_val
    # Represent integral doubles as JInt (matches how JS integers arrive)
    if d == float64(int64(d)) and d >= float64(low(int64)) and d <= float64(high(int64)):
      result = newJInt(int64(d))
    else:
      result = newJFloat(d)
  of JSON_KIND_STRING:
    result = newJString(if jv.string_val == nil: "" else: $jv.string_val)
  of JSON_KIND_ARRAY:
    result = newJArray()
    if jv.array_val != nil:
      let n = vecJVLen(jv.array_val)
      for i in 0.csize_t ..< n:
        result.add jsonValueToNode(vecJVGet(jv.array_val, i))
  of JSON_KIND_OBJECT:
    result = newJObject()
    if jv.object_val != nil:
      let cap = mapJVCap(jv.object_val)
      for i in 0.csize_t ..< cap:
        if mapJVOccupied(jv.object_val, i):
          let key = mapJVKeyAt(jv.object_val, i)
          let val = mapJVValAt(jv.object_val, i)
          if key != nil:
            result[$key] = jsonValueToNode(val)
  else:
    result = newJNull()

# ---------------------------------------------------------------------------

type SnapEntry = object
  name: cstring              # borrows the registry's Nim-string buffer (app-lifetime,
                             # append-only, never freed; worker only reads) — safe.
  handler: AppServiceHandler

var gSnap: seq[SnapEntry]    # built once on the MAIN thread at boot; read-only after

proc buildWorkerServiceSnapshot*() =
  ## MAIN thread, after app.service.add calls + runStartupAll, before workers
  ## spawn. Fills gSnap from the real registry so worker pthreads can dispatch
  ## without touching the main-heap seq.
  gSnap = @[]
  for (name, handler) in registeredServices():
    gSnap.add SnapEntry(name: name.cstring, handler: handler)

proc registerWorkerServices*() =
  ## Alias kept for any call site that predates the rename; delegates to the
  ## real snapshot builder so all paths converge.
  buildWorkerServiceSnapshot()

proc zapp_worker_thread_gc_init*() {.exportc, cdecl.} =
  ## Called by zjs.c ONCE on each worker pthread before its message loop, so the
  ## thread can run Nim GC code (service handlers alloc on this thread's heap).
  setupForeignThreadGc()

var tlResult {.threadvar.}: string   # per-worker-thread root; cstring borrows this buffer

proc service_invoke_native*(app: pointer, methodName: cstring, args: pointer): cstring
    {.exportc, cdecl.} =
  ## Worker pthread (foreign-thread GC already set up by zapp_worker_thread_gc_init).
  ## Runs the real handler inline. args is JsonValue* (bridged by jsonValueToNode).
  ## Returns a cstring valid until the next call on this thread (zjs.c copies
  ## synchronously). Empty string = not found.
  for e in gSnap:
    if e.name == methodName:               # cstring content compare (C strcmp), no alloc
      let node = jsonValueToNode(args)     # bridge JsonValue* → JsonNode (Task 4)
      tlResult = e.handler(nil, node)     # nil app — pure-only contract (spec)
      return tlResult.cstring
  return cstring""
