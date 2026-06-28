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
  doAssert o.vibrancy == Material.Sidebar
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
  doAssert o.sidebar.presentation == SidebarPresentation.Overlay, "sidebar.presentation must parse to the enum"

block:
  # sidebar.presentation absent → sidebar.presentation defaults to "".
  let o = WindowOptions(title: "pres-default")
  windowOptsApplyJson(o, parseJson("""{"sidebar":{"url":"#sb"}}"""))
  doAssert o.sidebar.presentation == SidebarPresentation.Default, "absent sidebar.presentation must default to Default"

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
  doAssert o.sidebar.material == Material.Default and o.inspector.material == Material.Default
  doAssert o.sidebar.presentation == SidebarPresentation.Default
  doAssert o.toolbar.style == ToolbarStyle.Unified, "toolbar style defaults to Unified"
  doAssert o.vibrancy == Material.Default

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
  let t = ToolbarOptions(style: ToolbarStyle.Expanded, items: @[
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
  doAssert "\"style\":\"expanded\"" in s, "toolbar style enum must serialize to its value"
  doAssert "\"type\":\"toggleSidebar\"" in s
  doAssert "\"pane\":\"sidebar\"" in s, "trackingSeparator must carry pane"
  doAssert "\"id\":\"compose\"" in s
  doAssert "\"enabled\":false" in s, "non-default enabled:false must serialize"
  doAssert "\"checked\":true" in s, "menu checked must serialize"
  doAssert "\"checked\":false" in s, "explicit checked:false must serialize"
  doAssert "\"indicator\":true" in s, "menu items emit the chevron indicator"
  doAssert parseToolbarJson(s) == t, "parse(serialize(t)) must round-trip (incl. enabled:false / checked:false)"

block:
  # toolbar trio fields round-trip (W2)
  let t = ToolbarOptions(style: ToolbarStyle.Unified, items: @[
    ToolbarItemOpt(`type`: "button", id: "go", label: "Go", enabled: true,
      indicator: true, bordered: false,
      style: ToolbarItemStyle.Prominent, tintColor: "#aa3bff",
      badge: ToolbarBadge(kind: ToolbarBadgeKind.Count, count: 3)),
    ToolbarItemOpt(`type`: "button", id: "tag", label: "Tag", enabled: true,
      indicator: true, bordered: true,
      badge: ToolbarBadge(kind: ToolbarBadgeKind.Dot)),
  ])
  let s = serializeToolbar(t)
  doAssert parseToolbarJson(s) == t, "parse(serialize(t)) must round-trip trio fields"
  # spot-check the wire keys native parses
  let root = parseJson(s)
  doAssert root["items"][0]["style"].getStr == "prominent"
  doAssert root["items"][0]["tintColor"].getStr == "#aa3bff"
  doAssert root["items"][0]["bordered"].getBool == false
  doAssert root["items"][0]["badge"]["kind"].getStr == "count"
  doAssert root["items"][0]["badge"]["count"].getInt == 3
  doAssert root["items"][1]["badge"]["kind"].getStr == "dot"

block:
  # windowOptsApplyJson parses an incoming toolbarJson STRING into o.toolbar.
  let o = WindowOptions(title: "tb")
  windowOptsApplyJson(o, parseJson(
    """{"toolbarJson":"{\"style\":\"unified\",\"items\":[{\"type\":\"button\",\"id\":\"go\",\"label\":\"Go\",\"icon\":\"\"}]}"}"""))
  doAssert o.toolbar.items.len == 1, "toolbarJson string must parse into o.toolbar"
  doAssert o.toolbar.items[0].id == "go" and o.toolbar.items[0].label == "Go"

block:
  # enum string values must equal the native/TS wire strings.
  doAssert $Material.Default == "", "Material.Default is the empty sentinel"
  doAssert $Material.Sidebar == "sidebar"
  doAssert $Material.HeaderView == "headerView"
  doAssert $Material.UnderWindowBackground == "underWindowBackground"
  doAssert $SidebarPresentation.Overlay == "overlay"
  doAssert $SidebarPresentation.Default == ""
  doAssert $ToolbarStyle.Unified == "unified"
  doAssert $ToolbarStyle.Expanded == "expanded"

block:
  let o = WindowOptions(title: "chrome")
  windowOptsApplyJson(o, parseJson("""{
    "vibrancy":"sidebar",
    "sidebar":{"url":"#sb","material":"headerView","presentation":"tile"},
    "inspector":{"url":"#insp","material":"popover"}
  }"""))
  doAssert o.vibrancy == Material.Sidebar
  doAssert o.sidebar.material == Material.HeaderView
  doAssert o.sidebar.presentation == SidebarPresentation.Tile
  doAssert o.inspector.material == Material.Popover

block:
  # unknown / absent enum strings fall back to the Default sentinel.
  let o = WindowOptions(title: "chrome-bad")
  windowOptsApplyJson(o, parseJson("""{"sidebar":{"material":"bogus","presentation":"nope"}}"""))
  doAssert o.sidebar.material == Material.Default, "unknown material must fall back to Default"
  doAssert o.sidebar.presentation == SidebarPresentation.Default, "unknown presentation must fall back to Default"

block:
  # segmented toolbar group round-trips (grouping)
  let t = ToolbarOptions(style: ToolbarStyle.Unified, items: @[
    ToolbarItemOpt(`type`: "segmented", id: "view",
      selectionMode: ToolbarGroupSelectionMode.One, selected: @[1],
      controlRepresentation: ToolbarControlRepresentation.Automatic,
      segments: @[
        ToolbarSegmentOpt(id: "grid", icon: "sf:square.grid.2x2", enabled: true),
        ToolbarSegmentOpt(id: "list", icon: "sf:list.bullet", enabled: true)]),
  ])
  let s = serializeToolbar(t)
  doAssert parseToolbarJson(s) == t, "parse(serialize(t)) must round-trip segmented group"
  let root = parseJson(s)
  doAssert root["items"][0]["type"].getStr == "segmented"
  doAssert root["items"][0]["selectionMode"].getStr == "one"
  doAssert root["items"][0]["selected"] == %*[1]
  doAssert root["items"][0]["segments"][0]["icon"].getStr == "sf:square.grid.2x2"

block:
  # plain group round-trips (grouping), including bordered:false sub-item
  let t = ToolbarOptions(style: ToolbarStyle.Unified, items: @[
    ToolbarItemOpt(`type`: "group", id: "nav",
      controlRepresentation: ToolbarControlRepresentation.Collapsed,
      items: @[
        ToolbarItemOpt(`type`: "button", id: "back", icon: "sf:chevron.left", enabled: true, indicator: true, bordered: true),
        ToolbarItemOpt(`type`: "button", id: "fwd", icon: "sf:chevron.right", enabled: true, indicator: true, bordered: true),
        ToolbarItemOpt(`type`: "button", id: "unbrd", icon: "sf:xmark", enabled: true, indicator: true, bordered: false)]),
  ])
  let s = serializeToolbar(t)
  doAssert parseToolbarJson(s) == t, "parse(serialize(t)) must round-trip plain group incl. bordered:false sub-item"
  let root = parseJson(s)
  doAssert root["items"][0]["type"].getStr == "group"
  doAssert root["items"][0]["id"].getStr == "nav"
  doAssert root["items"][0]["controlRepresentation"].getStr == "collapsed"
  doAssert root["items"][0]["items"][0]["id"].getStr == "back"
  doAssert root["items"][0]["items"][1]["id"].getStr == "fwd"
  doAssert root["items"][0]["items"][2]["bordered"].getBool == false, "bordered:false sub-item must appear on wire"
  doAssert not root["items"][0]["items"][0].hasKey("bordered"), "bordered:true sub-item must be omitted from wire (default)"

block:
  # #706: segmented momentary + Collapsed representation + empty selected round-trips
  let t = ToolbarOptions(style: ToolbarStyle.Unified, items: @[
    ToolbarItemOpt(`type`: "segmented", id: "fmt",
      selectionMode: ToolbarGroupSelectionMode.Momentary, selected: @[],
      controlRepresentation: ToolbarControlRepresentation.Collapsed,
      segments: @[
        ToolbarSegmentOpt(id: "b", label: "B", enabled: true),
        ToolbarSegmentOpt(id: "i", label: "I", enabled: true)]),
  ])
  let s = serializeToolbar(t)
  doAssert parseToolbarJson(s) == t, "parse(serialize(t)) must round-trip momentary + Collapsed segmented"
  let root = parseJson(s)
  doAssert root["items"][0]["selectionMode"].getStr == "momentary"
  doAssert root["items"][0]["controlRepresentation"].getStr == "collapsed"
  doAssert root["items"][0]["selected"].len == 0, "empty selected must serialize as []"

block:
  # label item round-trips (type:"label" text field)
  let t = ToolbarOptions(style: ToolbarStyle.Unified, items: @[
    ToolbarItemOpt(`type`: "label", id: "status", text: "Synced"),
    ToolbarItemOpt(`type`: "button", id: "refresh", label: "Refresh", enabled: true,
      indicator: true, bordered: true),
  ])
  let s = serializeToolbar(t)
  doAssert "\"type\":\"label\"" in s, "label type must serialize"
  doAssert "\"id\":\"status\"" in s, "label id must serialize"
  doAssert "\"text\":\"Synced\"" in s, "label text must serialize"
  doAssert parseToolbarJson(s) == t, "parse(serialize(t)) must round-trip label item"
  let root = parseJson(s)
  doAssert root["items"][0]["type"].getStr == "label"
  doAssert root["items"][0]["id"].getStr == "status"
  doAssert root["items"][0]["text"].getStr == "Synced"

block:
  # placement round-trips (leading default + center/trailing)
  let t = ToolbarOptions(style: ToolbarStyle.Unified, items: @[
    ToolbarItemOpt(`type`: "toggleSidebar"),                              # default Leading
    ToolbarItemOpt(`type`: "button", id: "status", label: "Hi",
                   placement: ToolbarPlacement.Center),
    ToolbarItemOpt(`type`: "button", id: "filter", label: "Filter",
                   placement: ToolbarPlacement.Trailing),
  ])
  let s = serializeToolbar(t)
  doAssert "\"placement\":\"leading\"" in s, "default placement must serialize as leading"
  doAssert "\"placement\":\"center\"" in s
  doAssert "\"placement\":\"trailing\"" in s
  doAssert parseToolbarJson(s) == t, "parse(serialize(t)) must round-trip placement"

echo "windowmanager ok"
