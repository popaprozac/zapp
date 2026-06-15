import ../service
import std/json

var shutOrder: seq[string]
proc h(args: JsonNode): string = ""
proc dn() = shutOrder.add "down"

proc test() =
  registerService("greet", h, shutdown = dn)
  # service_get_manifest_json returns a cstring; $ converts for comparison.
  doAssert $service_get_manifest_json() ==
    """{"v":1,"services":[{"name":"greet"}]}"""
  service_run_shutdown_all()           # C-ABI wrapper must run the shutdown hooks
  doAssert shutOrder == @["down"]
  echo "service cabi ok"
test()
