# Unit test for window.nim's WindowManager (id/slot allocation) + windowOptsApplyJson.
# Stubs the darwin window symbols window.nim importc's (no AppKit in the test).
import std/json
import std/strutils
import ../window
import ../appconfig

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

proc darwin_webview_eval_all(js: cstring) {.exportc, cdecl.} = discard
proc zjs_broadcast_eval_js(js: cstring) {.exportc, cdecl.} = discard

var gDevTools: cint = 0
proc zapp_build_dev_tools_default(): cint {.exportc, cdecl.} = gDevTools

block:
  let a = createWindow(WindowOptions(title: "a"))
  let b = createWindow(WindowOptions(title: "b"))
  doAssert b.id == a.id + 1, "plain windows must consume exactly one id each"

block:
  let o = WindowOptions(title: "sb")
  o.sidebar.url = "#sidebar-pane"
  let w = createWindow(o)
  doAssert o.sidebar.numericId == w.id + 1, "sidebar slot must follow the window id"
  let after = createWindow(WindowOptions(title: "after"))
  doAssert after.id == w.id + 2, "sidebar must consume a second id from the same space"

block:
  let o = WindowOptions(title: "both")
  o.sidebar.url = "#sidebar-pane"
  o.inspector.url = "#inspector-pane"
  let w = createWindow(o)
  doAssert o.sidebar.numericId == w.id + 1
  doAssert o.inspector.numericId == w.id + 2
  let after = createWindow(WindowOptions(title: "after2"))
  doAssert after.id == w.id + 3, "sidebar+inspector consume two extra ids"

block:
  let o = WindowOptions(title: "plain")
  discard createWindow(o)
  doAssert o.sidebar.numericId == -1 and o.inspector.numericId == -1

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
  doAssert o.sidebar.url == "#sb" and o.sidebar.width == 240'i32
  doAssert o.inspector.url == "#insp" and o.inspector.collapsed == true
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
  # sidebar.presentation parses into sidebar.presentation.
  let o = WindowOptions(title: "pres")
  windowOptsApplyJson(o, parseJson("""{"sidebar":{"url":"#sb","width":240,"presentation":"overlay"}}"""))
  doAssert o.sidebar.presentation == "overlay", "sidebar.presentation must parse to o.sidebar.presentation"

block:
  # sidebar.presentation absent → sidebar.presentation defaults to "".
  let o = WindowOptions(title: "pres-default")
  windowOptsApplyJson(o, parseJson("""{"sidebar":{"url":"#sb"}}"""))
  doAssert o.sidebar.presentation == "", "absent sidebar.presentation must default to empty string"

block:
  # Partial object-literal construction must fill the field defaults — the
  # load-bearing guarantee (window.m clamps panes to wopts_sidebar_max_width
  # literally, so a 0 default = invisible sidebar, #460). Replaces the old
  # newWindowOptions defaults.
  let o = WindowOptions(title: "x")
  doAssert o.width == 1200'i32 and o.height == 800'i32
  doAssert o.visible == true and o.acceptFirstMouse == true and o.autoCenter == false
  doAssert o.sidebar.width == 260'i32 and o.sidebar.maxWidth == 400'i32
  doAssert o.inspector.width == 280'i32 and o.inspector.maxWidth == 400'i32
  doAssert o.sidebar.collapsible == true and o.inspector.collapsible == true
  doAssert o.numericIdPrealloc == -1'i32 and o.asSheetOfId == -1'i32
  doAssert o.inspectable == Inspectable.Inherit, "window inspectable defaults to Inherit"
  doAssert o.titleBarStyle == TitleBarStyle.Unset, "Unset (ord 3) must be the default, not Default"
  doAssert o.trafficLights.close == ButtonState.Enabled

block:
  # Inspectable cascade: window-explicit > AppConfig > dev/prod.
  gDevTools = 0
  doAssert resolveInspectable(Inspectable.On)
  doAssert not resolveInspectable(Inspectable.Off)
  gDevTools = 1
  doAssert resolveInspectable(Inspectable.Auto)
  gDevTools = 0
  doAssert not resolveInspectable(Inspectable.Auto)
  setAppConfig(AppConfig(name: "t", inspectable: Inspectable.On, maxWorkers: 0))
  doAssert resolveInspectable(Inspectable.Inherit)
  setAppConfig(AppConfig(name: "t", inspectable: Inspectable.Off, maxWorkers: 0))
  doAssert not resolveInspectable(Inspectable.Inherit)
  setAppConfig(AppConfig(name: "t", inspectable: Inspectable.Auto, maxWorkers: 0))
  gDevTools = 1
  doAssert resolveInspectable(Inspectable.Inherit)
  gDevTools = 0
  doAssert not resolveInspectable(Inspectable.Inherit)

block:
  # serializeToolbar emits the native wire schema; parseToolbarJson is its inverse.
  let t = ToolbarOptions(style: "unified", items: @[
    ToolbarItemOpt(`type`: "toggleSidebar"),
    ToolbarItemOpt(`type`: "trackingSeparator", pane: "sidebar"),
    ToolbarItemOpt(`type`: "button", id: "compose", label: "Compose", icon: "sf:square.and.pencil"),
    ToolbarItemOpt(`type`: "button", id: "archive", label: "Archive", enabled: false),  # non-default enabled
    ToolbarItemOpt(`type`: "flexibleSpace"),
    ToolbarItemOpt(`type`: "button", id: "filter", icon: "sf:line.3.horizontal.decrease",
                   menu: @[
                     MenuItemOpt(id: "all", label: "All", checked: true),
                     MenuItemOpt(id: "unread", label: "Unread", checked: false)]),  # explicit checked:false
  ])
  let s = serializeToolbar(t)
  doAssert "\"style\":\"unified\"" in s, "style must serialize"
  doAssert "\"type\":\"toggleSidebar\"" in s
  doAssert "\"pane\":\"sidebar\"" in s, "trackingSeparator must carry pane"
  doAssert "\"id\":\"compose\"" in s
  doAssert "\"enabled\":false" in s, "non-default enabled:false must serialize"
  doAssert "\"checked\":true" in s, "menu checked must serialize"
  doAssert "\"checked\":false" in s, "explicit checked:false must serialize"
  doAssert "\"indicator\":true" in s, "menu items emit the chevron indicator"
  doAssert parseToolbarJson(s) == t, "parse(serialize(t)) must round-trip (incl. enabled:false / checked:false)"

block:
  # windowOptsApplyJson parses an incoming toolbarJson STRING into o.toolbar.
  let o = WindowOptions(title: "tb")
  windowOptsApplyJson(o, parseJson(
    """{"toolbarJson":"{\"style\":\"unified\",\"items\":[{\"type\":\"button\",\"id\":\"go\",\"label\":\"Go\",\"icon\":\"\"}]}"}"""))
  doAssert o.toolbar.items.len == 1, "toolbarJson string must parse into o.toolbar"
  doAssert o.toolbar.items[0].id == "go" and o.toolbar.items[0].label == "Go"

echo "windowmanager ok"
