import ../service
import ../apptypes
import std/json

proc h(app: App, args: JsonNode): string = ""

proc test() =
  doAssert serviceManifestJson() == """{"v":1,"services":[]}"""
  registerService("greet", h)
  registerService("ping", h)
  doAssert serviceManifestJson() ==
    """{"v":1,"services":[{"name":"greet"},{"name":"ping"}]}"""
  echo "service manifest ok"
test()
