import ../service
import std/json

proc h(args: JsonNode): string = ""

proc test() =
  doAssert serviceManifestJson() == """{"v":1,"services":[]}"""
  registerService("greet", h)
  registerService("ping", h)
  doAssert serviceManifestJson() ==
    """{"v":1,"services":[{"name":"greet"},{"name":"ping"}]}"""
  echo "service manifest ok"
test()
