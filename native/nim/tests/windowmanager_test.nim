# Unit test for window.nim's WindowManager (id/slot allocation) + windowOptsApplyJson.
# Stubs the darwin window symbols window.nim importc's (no AppKit in the test).
import std/json
import std/strutils
import ../window

proc darwin_window_create(opts: pointer): pointer {.exportc, cdecl.} = cast[pointer](1)
proc darwin_window_register_numeric_id(handle: pointer, id: int32) {.exportc, cdecl.} = discard
proc darwin_window_get_by_numeric_id(numericId: int32): pointer {.exportc, cdecl.} = nil
proc darwin_window_attach_modal(parent, modal: pointer) {.exportc, cdecl.} = discard
proc darwin_window_numeric_id_for_string(wid: cstring): int32 {.exportc, cdecl.} =
  ## Mimic the .m registry: "win-<n>" -> n, else -1.
  let s = $wid
  if s.len > 4 and s[0..3] == "win-":
    (try: parseInt(s[4..^1]).int32 except ValueError: -1'i32)
  else: -1'i32

block:
  let a = createWindow(newWindowOptions("a"))
  let b = createWindow(newWindowOptions("b"))
  doAssert b.id == a.id + 1, "plain windows must consume exactly one id each"

block:
  let o = newWindowOptions("sb")
  o.sidebarUrl = "#sidebar-pane"
  let w = createWindow(o)
  doAssert o.sidebarNumericId == w.id + 1, "sidebar slot must follow the window id"
  let after = createWindow(newWindowOptions("after"))
  doAssert after.id == w.id + 2, "sidebar must consume a second id from the same space"

block:
  let o = newWindowOptions("both")
  o.sidebarUrl = "#sidebar-pane"
  o.inspectorUrl = "#inspector-pane"
  let w = createWindow(o)
  doAssert o.sidebarNumericId == w.id + 1
  doAssert o.inspectorNumericId == w.id + 2
  let after = createWindow(newWindowOptions("after2"))
  doAssert after.id == w.id + 3, "sidebar+inspector consume two extra ids"

block:
  let o = newWindowOptions("plain")
  discard createWindow(o)
  doAssert o.sidebarNumericId == -1 and o.inspectorNumericId == -1

block:
  let s1 = allocSlot()
  let s2 = allocSlot()
  doAssert s2 == s1 + 1, "allocSlot must be monotonic"

block:
  let o = newWindowOptions("base")
  o.width = 100; o.height = 100
  let a = parseJson("""{
    "title":"Hi","width":800.5,"height":600,"vibrancy":"sidebar",
    "titleBarStyle":"hiddenInset","closable":false,
    "sidebar":{"url":"#sb","width":240},
    "inspector":{"url":"#insp","collapsed":true},
    "asSheetOf":"win-7","presentation":"bottomSheet","detents":["small","medium","large"],
    "grabber":true
  }""")
  windowOptsApplyJson(o, a)
  doAssert o.title == "Hi"
  doAssert o.width == 800'i32, "fractional dims must use getFloat (not truncate to 0)"
  doAssert o.height == 600'i32
  doAssert o.vibrancy == "sidebar"
  doAssert o.titleBarStyle == TitleBarStyle.HiddenInset
  doAssert o.closable == false and o.trafficLights.close == ButtonState.Disabled
  doAssert o.sidebarUrl == "#sb" and o.sidebarWidth == 240'i32
  doAssert o.inspectorUrl == "#insp" and o.inspectorCollapsed == true
  doAssert o.asSheetOfId == 7'i32, "asSheetOf string win-7 must parse to 7"
  doAssert o.sheetPresentation == 3'i32
  doAssert o.sheetDetents == 7'i32, "small|medium|large => bits 4|1|2 = 7"
  doAssert o.sheetGrabber == true

block:
  let o = newWindowOptions("def")
  doAssert o.titleBarStyle == TitleBarStyle.Unset, "default titleBarStyle must be Unset (use chrome default)"
  windowOptsApplyJson(o, parseJson("{}"))
  doAssert o.title == "def" and o.asSheetOfId == -1'i32
  doAssert o.titleBarStyle == TitleBarStyle.Unset, "omitting titleBarStyle must keep Unset"
  windowOptsApplyJson(o, parseJson("""{"titleBarStyle":"default"}"""))
  doAssert o.titleBarStyle == TitleBarStyle.Default,
    "explicit 'default' must force Default (overrides the split-window chrome default)"

echo "windowmanager ok"
