# NOTE: this Nim version's call-form {.compile(path, flags).} requires exactly
# 2 arguments (a bare {.compile(path).} errors: "'.compile' pragma takes up 2
# arguments") -- deviates from the brief's 1-arg sketch; empty flags string.
{.compile("../../shared/jslit.c", "").}
import std/json
proc zapp_js_lit_dup(utf8: cstring): cstring {.importc, cdecl.}
proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>", cdecl.}
proc lit(s: string): string =
  let c = zapp_js_lit_dup(s.cstring); result = $c; c_free(c)

doAssert lit("a'b") == "\"a'b\""
doAssert lit("a\"b") == "\"a\\\"b\""
doAssert lit("a\\b") == "\"a\\\\b\""
doAssert lit("x\ny") == "\"x\\ny\""
for s in ["plain", "a'b", "a\"b", "a\\b", "x\ny\tz", "');x//", "  spaces  "]:
  doAssert parseJson(lit(s)).getStr == s   # round-trips through JSON == exact input
echo "jslit_test OK"
