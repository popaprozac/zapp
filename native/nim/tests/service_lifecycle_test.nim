import ../service
import std/json

var order: seq[string]
proc h(args: JsonNode): string = ""
proc upA() = order.add "startA"
proc dnA() = order.add "stopA"
proc upB() = order.add "startB"
proc dnB() = order.add "stopB"

proc test() =
  registerService("A", h, startup = upA, shutdown = dnA)
  registerService("B", h, startup = upB, shutdown = dnB)
  registerService("C", h)                       # no hooks -> skipped
  runStartupAll()
  doAssert order == @["startA", "startB"]        # forward registration order
  runShutdownAll()
  doAssert order == @["startA", "startB", "stopB", "stopA"]   # reverse order
  echo "service lifecycle ok"
test()
