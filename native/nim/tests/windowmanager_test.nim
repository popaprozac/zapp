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
  let a = createWindow(WindowOptions(title: "a"))
  let b = createWindow(WindowOptions(title: "b"))
  doAssert b.id == a.id + 1, "plain windows must consume exactly one id each"

block:
  let o = WindowOptions(title: "sb")
  o.sidebarUrl = "#sidebar-pane"
  let w = createWindow(o)
  doAssert o.sidebarNumericId == w.id + 1, "sidebar slot must follow the window id"
  let after = createWindow(WindowOptions(title: "after"))
  doAssert after.id == w.id + 2, "sidebar must consume a second id from the same space"

block:
  let o = WindowOptions(title: "both")
  o.sidebarUrl = "#sidebar-pane"
  o.inspectorUrl = "#inspector-pane"
  let w = createWindow(o)
  doAssert o.sidebarNumericId == w.id + 1
  doAssert o.inspectorNumericId == w.id + 2
  let after = createWindow(WindowOptions(title: "after2"))
  doAssert after.id == w.id + 3, "sidebar+inspector consume two extra ids"

block:
  let o = WindowOptions(title: "plain")
  discard createWindow(o)
  doAssert o.sidebarNumericId == -1 and o.inspectorNumericId == -1

block:
  let s1 = allocSlot()
  let s2 = allocSlot()
  doAssert s2 == s1 + 1, "allocSlot must be monotonic"

block:
  let o = WindowOptions(title: "base")
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
  let o = WindowOptions(title: "def")
  doAssert o.titleBarStyle == TitleBarStyle.Unset, "default titleBarStyle must be Unset (use chrome default)"
  windowOptsApplyJson(o, parseJson("{}"))
  doAssert o.title == "def" and o.asSheetOfId == -1'i32
  doAssert o.titleBarStyle == TitleBarStyle.Unset, "omitting titleBarStyle must keep Unset"
  windowOptsApplyJson(o, parseJson("""{"titleBarStyle":"default"}"""))
  doAssert o.titleBarStyle == TitleBarStyle.Default,
    "explicit 'default' must force Default (overrides the split-window chrome default)"

block:
  # Partial object-literal construction must fill the field defaults — the
  # load-bearing guarantee (window.m clamps panes to wopts_sidebar_max_width
  # literally, so a 0 default = invisible sidebar, #460). Replaces the old
  # newWindowOptions defaults.
  let o = WindowOptions(title: "x")
  doAssert o.width == 1200'i32 and o.height == 800'i32
  doAssert o.visible == true and o.acceptFirstMouse == true and o.autoCenter == false
  doAssert o.sidebarWidth == 260'i32 and o.sidebarMaxWidth == 400'i32
  doAssert o.inspectorWidth == 280'i32 and o.inspectorMaxWidth == 400'i32
  doAssert o.sidebarCollapsible == true and o.inspectorCollapsible == true
  doAssert o.numericIdPrealloc == -1'i32 and o.asSheetOfId == -1'i32
  doAssert o.inspectable == TriState.Unset
  doAssert o.titleBarStyle == TitleBarStyle.Unset, "Unset (ord 3) must be the default, not Default"
  doAssert o.trafficLights.close == ButtonState.Enabled

echo "windowmanager ok"
