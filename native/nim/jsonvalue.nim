## JsonValue C-ABI provider (Nim). Once wired (the cutover commit that follows
## in this series), it replaces the zc-transpiled .zapp/zjson_provider.o.
##
## zjs.c (C) builds JSON argument trees on the worker pthread via the
## JsonValue__* / json_*_owned / json_free_tree symbols below, hands the opaque
## pointer to service_invoke_native, which casts it straight back to a std/json
## JsonNode (no walk). zjs.c is WRITE-ONLY on the value and never dereferences
## the pointer, so the opaque token can be a Nim JsonNode masquerading as the
## `JsonValue*` zjs.c externs. The zc build keeps resolving these symbols to
## zc's std/json — the seam signature is identical in both builds.
##
## Memory model (mirrors the manual-C ownership zjs.c relies on):
##   - Constructors: newX() (refcount 1), GC_ref (2); the owning local's
##     scope-exit decref (→1) leaves net refcount 1 = the "C pin" zjs.c holds.
##   - _owned setters: absorb the child into the parent container (which increfs
##     it), then GC_unref the child's construction pin → the container is sole
##     owner. Casts bind to {.cursor.} locals so ORC inserts no stray decref.
##   - json_free_tree: one GC_unref on the root; ORC cascades the free.
##
## Everything here runs on the worker pthread, where foreign-thread GC is
## already initialised (zapp_worker_thread_gc_init) before any symbol is
## reachable, so ORC alloc/free is safe.
import std/json

# JS numbers are all doubles; represent an integral double as JInt so handlers
# see ints (matches the coercion the old jsonValueToNode walker did).
proc numberNode(n: float): JsonNode =
  # JS numbers are doubles; represent an exactly-integral double that fits int64
  # as JInt so handlers see ints. The bound check MUST precede int64(n) (an
  # out-of-range float→int64 conversion is UB under -d:release). The upper bound
  # is EXCLUSIVE: float(high(int64)) rounds up to 2^63, so `<=` would admit 2^63
  # and saturate it to 2^63-1; `< 2^63` sends 2^63 (and larger) to JFloat.
  if n >= float(low(int64)) and n < 9223372036854775808.0 and n == float(int64(n)):
    newJInt(int64(n))
  else:
    newJFloat(n)

proc jvNull*(): pointer {.exportc: "JsonValue__null_ptr", cdecl.} =
  let n = newJNull(); GC_ref(n); cast[pointer](n)

proc jvBool*(b: bool): pointer {.exportc: "JsonValue__bool_ptr", cdecl.} =
  let n = newJBool(b); GC_ref(n); cast[pointer](n)

proc jvNumber*(n: cdouble): pointer {.exportc: "JsonValue__number_ptr", cdecl.} =
  let node = numberNode(n.float); GC_ref(node); cast[pointer](node)

proc jvString*(s: cstring): pointer {.exportc: "JsonValue__string_ptr", cdecl.} =
  # Copies s — zjs.c passes a transient buffer.
  let n = newJString(if s.isNil: "" else: $s); GC_ref(n); cast[pointer](n)

proc jvArray*(): pointer {.exportc: "JsonValue__array_ptr", cdecl.} =
  let n = newJArray(); GC_ref(n); cast[pointer](n)

proc jvObject*(): pointer {.exportc: "JsonValue__object_ptr", cdecl.} =
  let n = newJObject(); GC_ref(n); cast[pointer](n)

proc jsonObjectSetOwned*(obj: pointer, key: cstring, val: pointer)
    {.exportc: "json_object_set_owned", cdecl.} =
  if obj.isNil or val.isNil: return
  let o {.cursor.} = cast[JsonNode](obj)
  let v {.cursor.} = cast[JsonNode](val)
  o[if key.isNil: "" else: $key] = v   # JObject slot increfs v; copies the key
  GC_unref(v)                          # release the child's construction pin

proc jsonArrayPushOwned*(arr: pointer, val: pointer)
    {.exportc: "json_array_push_owned", cdecl.} =
  if arr.isNil or val.isNil: return
  let a {.cursor.} = cast[JsonNode](arr)
  let v {.cursor.} = cast[JsonNode](val)
  a.add v               # JArray seq increfs v
  GC_unref(v)           # release the child's construction pin

proc jsonFreeTree*(v: pointer) {.exportc: "json_free_tree", cdecl.} =
  if v.isNil: return
  let n {.cursor.} = cast[JsonNode](v)
  GC_unref(n)           # ORC cascades the free through the graph

template withArgsNode*(p: pointer, body: untyped) =
  ## Borrow a C-owned JsonNode for the duration of `body` WITHOUT taking
  ## ownership (handlers are pure-only on the worker invoke path; C still owns
  ## and frees via json_free_tree). nil → a fresh JNull (the "no args" case).
  ## Injects `argsNode: JsonNode` into `body`.
  if p == nil:
    let argsNode {.inject.} = newJNull()
    body
  else:
    let argsNode {.inject, cursor.} = cast[JsonNode](p)
    body
