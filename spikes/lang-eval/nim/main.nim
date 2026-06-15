import std/json

{.passC: "-I spikes/lang-eval/shared".}
{.passL: "spikes/lang-eval/shared/probe_cocoa.o -framework Cocoa -lobjc".}

proc spike_cocoa_open_window(w, h: cint, title: cstring) {.importc, cdecl.}
proc spike_print_windows() {.importc, cdecl.}

let cfg = parseFile("spikes/lang-eval/shared/sample.json")
let w = cfg["w"].getInt.cint
let h = cfg["h"].getInt.cint
let title = cfg["title"].getStr

when defined(macosx):
  spike_cocoa_open_window(w, h, title.cstring)
else:
  spike_print_windows()
