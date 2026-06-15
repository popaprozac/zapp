import ../service
import std/[json, options]

proc handlerA(args: JsonNode): string = """{"a":1}"""

proc test() =
  registerService("svcA", handlerA)
  doAssert invokeService("svcA", newJNull()).get == """{"a":1}"""
  doAssert invokeService("missing", newJNull()).isNone
  echo "service registry ok"
test()
