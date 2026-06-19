# Unit test for the Nim JsonValue C-ABI provider (jsonvalue.nim).
# Builds JSON trees through the SAME C-ABI symbols zjs.c calls, reads them back
# by casting the opaque pointer to a std/json JsonNode (the production read
# path), and frees them via json_free_tree. Also stresses build+free to surface
# leaks / double-frees under ORC.
import ../jsonvalue
import std/json

proc test() =
  # free(nil) is a no-op
  jsonFreeTree(nil)

  # --- scalars round-trip ---
  block:
    let p = jvNull()
    doAssert (cast[JsonNode](p)).kind == JNull
    jsonFreeTree(p)
  block:
    let p = jvBool(true)
    doAssert cast[JsonNode](p) == newJBool(true)
    jsonFreeTree(p)
  block:
    # integral double → JInt (matches the old jsonValueToNode coercion)
    let p = jvNumber(42.0)
    let n = cast[JsonNode](p)
    doAssert n.kind == JInt and n.getInt == 42
    jsonFreeTree(p)
  block:
    let p = jvNumber(3.5)
    doAssert (cast[JsonNode](p)).kind == JFloat
    jsonFreeTree(p)
  block:
    # 2^63 is out of int64 range → JFloat, not a silently-saturated JInt
    let p = jvNumber(9223372036854775808.0)
    doAssert (cast[JsonNode](p)).kind == JFloat
    jsonFreeTree(p)
  block:
    # a large in-range integral double stays JInt (no precision loss at 2^53)
    let p = jvNumber(9007199254740992.0)
    let n = cast[JsonNode](p)
    doAssert n.kind == JInt and n.getInt == 9007199254740992
    jsonFreeTree(p)
  block:
    let p = jvString(cstring"hi")
    doAssert cast[JsonNode](p) == newJString("hi")
    jsonFreeTree(p)
  block:
    # nil cstring → empty string, not a crash
    let p = jvString(nil)
    doAssert cast[JsonNode](p) == newJString("")
    jsonFreeTree(p)

  # --- nested object {"s":"y","n":7,"ok":true,"xs":[1,2],"sub":{"a":1}} ---
  block:
    let obj = jvObject()
    jsonObjectSetOwned(obj, cstring"s", jvString(cstring"y"))
    jsonObjectSetOwned(obj, cstring"n", jvNumber(7.0))
    jsonObjectSetOwned(obj, cstring"ok", jvBool(true))
    let xs = jvArray()
    jsonArrayPushOwned(xs, jvNumber(1.0))
    jsonArrayPushOwned(xs, jvNumber(2.0))
    jsonObjectSetOwned(obj, cstring"xs", xs)
    let sub = jvObject()
    jsonObjectSetOwned(sub, cstring"a", jvNumber(1.0))
    jsonObjectSetOwned(obj, cstring"sub", sub)

    let node {.cursor.} = cast[JsonNode](obj)
    doAssert node.kind == JObject
    doAssert node["s"] == newJString("y")
    doAssert node["n"].getInt == 7
    doAssert node["ok"] == newJBool(true)
    doAssert node["xs"].kind == JArray and node["xs"].len == 2
    doAssert node["xs"][0].getInt == 1 and node["xs"][1].getInt == 2
    doAssert node["sub"]["a"].getInt == 1
    jsonFreeTree(obj)   # single GC_unref on root → ORC cascades the free

  # --- build+free stress: net-zero refcount per iteration, no growth ---
  for i in 0 ..< 2000:
    let o = jvObject()
    jsonObjectSetOwned(o, cstring"k", jvString(cstring"v"))
    let a = jvArray()
    jsonArrayPushOwned(a, jvNumber(float(i)))
    jsonObjectSetOwned(o, cstring"xs", a)
    jsonFreeTree(o)

  echo "jsonvalue ok"

test()
