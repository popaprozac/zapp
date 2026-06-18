## Tests for worker_service.nim snapshot + dispatch (Task 3 + Task 4).
## Registers a real service via registerService, builds the snapshot via
## buildWorkerServiceSnapshot (or the registerWorkerServices alias), then
## exercises service_invoke_native on the calling thread (no pthread needed —
## the cstring compare + dispatch are testable inline).
##
## Task 4 tests cover jsonValueToNode:
##   - nil → JNull (safe path, no provider needed)
##   - Scalar round-trips: null, bool, int number, float number, string
##     via the JsonValue__*_ptr constructors from zjson_provider.o.
##   - Array/object constructed via _zapp_build_arr / _zapp_build_obj
##     C helpers emitted inline (json_array_push_owned has a guard bug in
##     the provider that compares arr->kind against the JsonType__JSON_ARRAY
##     function pointer rather than calling it; our helpers bypass that guard
##     by using Vec__JsonValuePtr__push and Map__JsonValuePtr__put directly).
##   - Full args round-trip via service_invoke_native (echo handler).
##   Full array/object insertion coverage is also exercised by the kitchen-
##   sink zjs smoke (real JS workers pass complex args through the walker).
##
## Link the pre-built JsonValue provider so the Vec/Map accessors resolve.
{.passL: "/Users/zach/code/zapp/kitchen-sink/.zapp/zjson_provider.o".}

import std/json
import ../apptypes  # App, AppServiceHandler
import ../service   # registerService (populate the real registry)
import ../worker_service

# ---------------------------------------------------------------------------
# JsonValue builder C-ABI — from zjson_provider.o (opaque pointer ABI).
# worker_service.nim already emits the struct declarations.
# ---------------------------------------------------------------------------
proc jvNull():   pointer {.importc: "JsonValue__null_ptr", cdecl.}
proc jvBool(b: bool):    pointer {.importc: "JsonValue__bool_ptr", cdecl.}
proc jvNum(n: cdouble):  pointer {.importc: "JsonValue__number_ptr", cdecl.}
proc jvStr(s: cstring):  pointer {.importc: "JsonValue__string_ptr", cdecl.}
proc jvArr():   pointer {.importc: "JsonValue__array_ptr", cdecl.}
proc jvObj():   pointer {.importc: "JsonValue__object_ptr", cdecl.}
# Vec/Map direct accessors (bypass json_builder's broken guard)
proc vecJVPush(v: pointer; val: pointer) {.importc: "Vec__JsonValuePtr__push", cdecl.}
proc mapJVPut(m: pointer; key: cstring; val: pointer) {.importc: "Map__JsonValuePtr__put", cdecl.}
proc jvFree(v: pointer) {.importc: "json_free_tree", cdecl.}

# ---------------------------------------------------------------------------
# Test helpers: build array/object by directly pushing into the inner
# Vec/Map, bypassing json_builder.zc's buggy guard (which compares
# arr->kind against the JsonType__JSON_ARRAY FUNCTION POINTER instead
# of calling it, so the guard always fires and drops the value).
# The emit block repeats the struct definitions because each Nim module
# compiles to its own C translation unit.
# ---------------------------------------------------------------------------
{.emit: """
#include <stddef.h>
#include <stdbool.h>

/* Repeat struct layout — each .nim → .c TU is independent */
typedef struct JsonValue JsonValue;
typedef struct {
    JsonValue** data;
    size_t len;
    size_t cap;
} Vec__JsonValuePtr;
typedef struct {
    char**      keys;
    JsonValue** vals;
    bool*       occupied;
    bool*       deleted;
    size_t      len;
    size_t      cap;
} Map__JsonValuePtr;
struct JsonValue {
    int               kind;
    char*             string_val;
    double            number_val;
    bool              bool_val;
    Vec__JsonValuePtr*  array_val;
    Map__JsonValuePtr*  object_val;
};

/* forward-declare the Vec/Map functions that are in zjson_provider.o */
extern void Vec__JsonValuePtr__push(Vec__JsonValuePtr* self, JsonValue* item);
extern void Map__JsonValuePtr__put(Map__JsonValuePtr* self, char* key, JsonValue* val);

void* _zapp_test_arr_push(void* arr_jv, void* val_jv) {
    struct JsonValue* a = (struct JsonValue*)arr_jv;
    Vec__JsonValuePtr__push(a->array_val, (struct JsonValue*)val_jv);
    return arr_jv;
}
void* _zapp_test_obj_set(void* obj_jv, const char* key, void* val_jv) {
    struct JsonValue* o = (struct JsonValue*)obj_jv;
    Map__JsonValuePtr__put(o->object_val, (char*)key, (struct JsonValue*)val_jv);
    return obj_jv;
}
""".}
proc testArrPush(arr: pointer; val: pointer): pointer
    {.importc: "_zapp_test_arr_push", cdecl, nodecl.}
proc testObjSet(obj: pointer; key: cstring; val: pointer): pointer
    {.importc: "_zapp_test_obj_set", cdecl, nodecl.}

# ---------------------------------------------------------------------------

proc greetHandler(app: App, args: JsonNode): string = "Hello from Zapp!"
proc echoHandler(app: App, args: JsonNode): string = $args

proc testSnapshot() =
  registerService("greet", greetHandler)
  registerService("echo", echoHandler)
  buildWorkerServiceSnapshot()

  # greet — ignores args, returns the real string
  doAssert $service_invoke_native(nil, cstring"greet", nil) == "Hello from Zapp!"
  # unknown method → empty string
  doAssert $service_invoke_native(nil, cstring"missing", nil) == ""
  # registerWorkerServices alias — idempotent rebuild, greet still works
  registerWorkerServices()
  doAssert $service_invoke_native(nil, cstring"greet", nil) == "Hello from Zapp!"
  echo "worker_service snapshot ok"

proc testJsonValueToNode() =
  ## Task 4: jsonValueToNode round-trips for all JSON types.

  # nil → JNull (safe path, no C accessor calls)
  doAssert jsonValueToNode(nil).kind == JNull
  echo "  jsonValueToNode(nil) ok"

  # null
  let jn = jvNull()
  doAssert jsonValueToNode(jn).kind == JNull
  jvFree(jn)
  echo "  jsonValueToNode(null) ok"

  # bool true / false
  let jbt = jvBool(true)
  let jbf = jvBool(false)
  doAssert jsonValueToNode(jbt) == newJBool(true)
  doAssert jsonValueToNode(jbf) == newJBool(false)
  jvFree(jbt); jvFree(jbf)
  echo "  jsonValueToNode(bool) ok"

  # integer number → JInt (42 is integral, should round-trip as JInt)
  let ji = jvNum(42.0)
  let jn42 = jsonValueToNode(ji)
  doAssert jn42.kind == JInt
  doAssert jn42.getInt() == 42
  jvFree(ji)
  echo "  jsonValueToNode(int number) ok"

  # float number → JFloat
  let jf = jvNum(3.14)
  let jn314 = jsonValueToNode(jf)
  doAssert jn314.kind == JFloat
  jvFree(jf)
  echo "  jsonValueToNode(float number) ok"

  # string
  let js = jvStr(cstring"hello")
  doAssert jsonValueToNode(js) == newJString("hello")
  jvFree(js)
  echo "  jsonValueToNode(string) ok"

  # array [true, 1] — use testArrPush (bypasses broken json_builder guard)
  let jarr = jvArr()
  discard testArrPush(jarr, jvBool(true))
  discard testArrPush(jarr, jvNum(1.0))
  let arrNode = jsonValueToNode(jarr)
  doAssert arrNode.kind == JArray
  doAssert arrNode.len == 2
  doAssert arrNode[0] == newJBool(true)
  doAssert arrNode[1].getInt() == 1
  jvFree(jarr)
  echo "  jsonValueToNode(array) ok"

  # object {"x": "y", "n": 7} — use testObjSet (bypasses broken guard)
  let jobj = jvObj()
  discard testObjSet(jobj, cstring"x", jvStr(cstring"y"))
  discard testObjSet(jobj, cstring"n", jvNum(7.0))
  let objNode = jsonValueToNode(jobj)
  doAssert objNode.kind == JObject
  doAssert objNode["x"] == newJString("y")
  doAssert objNode["n"].getInt() == 7
  jvFree(jobj)
  echo "  jsonValueToNode(object) ok"

  # args round-trip via service_invoke_native (echo handler returns $args)
  let echoPld = jvObj()
  discard testObjSet(echoPld, cstring"msg", jvStr(cstring"ping"))
  let echoResult = $service_invoke_native(nil, cstring"echo", echoPld)
  # echoResult is the JSON serialisation of the JsonNode; must contain "msg"
  doAssert echoResult.len > 0
  var foundMsg = false
  for i in 0 ..< echoResult.len - 2:
    if echoResult[i] == 'm' and echoResult[i+1] == 's' and echoResult[i+2] == 'g':
      foundMsg = true
      break
  doAssert foundMsg
  jvFree(echoPld)
  echo "  service_invoke_native echo args round-trip ok"

  echo "worker_service jsonValueToNode ok"

testSnapshot()
testJsonValueToNode()
