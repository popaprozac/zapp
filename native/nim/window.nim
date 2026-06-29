## Window value + the opaque-handle C-ABI bridge to the untouched darwin
## window.m / webview.m. window.m reads a `WindowOptions*` purely through the
## `wopts_*` accessor functions (it never sees the struct layout), so we model
## WindowOptions as a Nim `ref object` and expose every accessor as an
## `{.exportc, cdecl.}` proc. The pointer C holds is the GC'd ref itself,
## pinned with `GC_ref` across `darwin_window_create`.
##
## BOUNDARY RULES: no {.emit.}; cstring accessors returning a non-empty value
## are backed by the ref's own (module-rooted, GC-pinned) string fields, so the
## cstring stays valid for window.m's synchronous read. Fields the skeleton
## never sets get sane defaults — window.m guards every optional feature behind
## a "url set?" / tag!=0 check, so the defaults never activate a code path.

import coretypes
export coretypes   # WindowOptions.inspectable is a coretypes.Inspectable
import std/json
import std/tables
import apptypes
export apptypes    # WindowManager visible to callers of window.nim
import appconfig
import color
export color   # ZappColor + converters reach app.nim through the WindowOptions API
import routerstate

# Per-window native-routing flag (N3a). Set in createWindow; queried by ios/routing.m.
var gNativeRouting: Table[int32, bool]
proc zapp_window_native_routing*(id: int32): bool {.exportc, cdecl.} =
  gNativeRouting.getOrDefault(id, false)

type
  TitleBarStyle* {.pure.} = enum   ## NSWindow title-bar style (window.m tag 0/1/2/3)
    Default = 0
    Hidden = 1
    HiddenInset = 2
    ## Unset = "app didn't pick a style; use the chrome default" — distinct from
    ## Default (explicit "standard title bar"). On a sidebar/inspector window only
    ## Unset gets the unified hidden-title chrome default; an explicit Default
    ## opts back into a standard title bar. Mirrors zc's TitleBarStyle + the
    ## inspectable cascade enum. Appended last to keep tags 0/1/2.
    Unset = 3

  Material* {.pure.} = enum   ## NSVisualEffectMaterial name (matches TS Material const)
    Default = ""              ## "" ⇒ native default
    Sidebar = "sidebar"
    HeaderView = "headerView"
    Titlebar = "titlebar"
    Menu = "menu"
    Popover = "popover"
    HudWindow = "hudWindow"
    FullScreenUI = "fullScreenUI"
    Sheet = "sheet"
    ContentBackground = "contentBackground"
    UnderWindowBackground = "underWindowBackground"
    UnderPageBackground = "underPageBackground"
    WindowBackground = "windowBackground"

  SidebarPresentation* {.pure.} = enum   ## sidebar tiling vs overlay
    Default = ""              ## "" ⇒ per-platform default (macOS tiles)
    Tile = "tile"
    Overlay = "overlay"

  BackgroundExtension* {.pure.} = enum  ## content-pane bg vs floating sidebar (macOS 26+)
    None = "none"             ## default: content sits beside the sidebar
    Extend = "extend"         ## content flows under the sidebar glass
    Mirror = "mirror"         ## NSBackgroundExtensionView mirrors/blurs behind glass

  ToolbarStyle* {.pure.} = enum          ## NSWindow.toolbarStyle
    Unified = "unified"       ## default
    UnifiedCompact = "unifiedCompact"
    Expanded = "expanded"

  ToolbarGroupSelectionMode* {.pure.} = enum   ## NSToolbarItemGroupSelectionMode
    Momentary = "momentary", One = "one", Any = "any"

  ToolbarControlRepresentation* {.pure.} = enum ## NSToolbarItemGroupControlRepresentation
    Automatic = "automatic", Expanded = "expanded", Collapsed = "collapsed"

  ToolbarPlacement* {.pure.} = enum    ## toolbar slot (macOS sort / future iOS nav-bar)
    Leading = "leading", Center = "center", Trailing = "trailing"

  ToolbarSegmentOpt* = object                  ## mirrors TS ToolbarSegmentDef (data only)
    id*, label*, icon*: string
    enabled*: bool = true

  ButtonState* {.pure.} = enum      ## a traffic-light button (window.m tag 0/1/2)
    Enabled = 0
    Disabled = 1
    Hidden = 2

  TrafficLights* = object           ## the three window buttons (zc TrafficLights struct)
    close*, minimize*, zoom*: ButtonState

  MenuItemOpt* = object              ## mirrors TS ZappMenuItem (toolbar pull-down item)
    id*, label*, icon*: string
    checked*: bool

  ToolbarItemStyle* {.pure.} = enum     ## NSToolbarItemStyle (macOS 26)
    Plain = "plain"
    Prominent = "prominent"

  ToolbarBadgeKind* {.pure.} = enum     ## NSItemBadge variant (macOS 26)
    None = "none", Count = "count", Text = "text", Dot = "dot"

  ToolbarBadge* = object                ## mirrors TS badge union
    kind*: ToolbarBadgeKind             ## None ⇒ no badge / clear
    count*: int
    text*: string

  ToolbarItemOpt* = object           ## mirrors TS ToolbarItemDef — DATA fields only (no action closure)
    id*: string
    `type`*: string                  ## "" ⇒ native treats as "button"
    pane*: string                    ## trackingSeparator: "sidebar" | "inspector"
    placement*: ToolbarPlacement = ToolbarPlacement.Leading   ## toolbar slot; default Leading
    label*, icon*, text*: string
    enabled*: bool = true
    indicator*: bool = true          ## menu chevron; native default YES; emitted only on menu items
    menu*: seq[MenuItemOpt]
    style*: ToolbarItemStyle            ## default Plain; macOS 26+
    tintColor*: string                  ## hex; emitted only when Prominent
    badge*: ToolbarBadge                ## kind None ⇒ omitted
    bordered*: bool = true
    segments*: seq[ToolbarSegmentOpt]            ## "segmented"
    selectionMode*: ToolbarGroupSelectionMode    ## default Momentary
    selected*: seq[int]                          ## indices; empty = none
    controlRepresentation*: ToolbarControlRepresentation  ## default Automatic
    items*: seq[ToolbarItemOpt]                  ## "group" sub-items (one level)

  ToolbarOptions* = object
    style*: ToolbarStyle
    items*: seq[ToolbarItemOpt]

  SidebarOptions* = object
    url*: string
    backgroundColor*: ZappColor
    material*: Material
    presentation*: SidebarPresentation
    width*: int32 = 260
    minWidth*: int32 = 180
    maxWidth*: int32 = 400
    collapsible*: bool = true
    collapsed*: bool
    resizable*: bool = true
    numericId*: int32 = -1

  InspectorOptions* = object
    url*: string
    backgroundColor*: ZappColor
    material*: Material
    width*: int32 = 280
    minWidth*: int32 = 180
    maxWidth*: int32 = 400
    collapsible*: bool = true
    collapsed*: bool
    resizable*: bool = true
    numericId*: int32 = -1

  WindowOptions* = ref object
    # --- set by the skeleton ---
    title*: string
    url*: string
    width*: int32 = 1200
    height*: int32 = 800
    x*, y*: int32
    autoCenter*: bool
    visible*: bool = true
    resizable*: bool = true
    closable*: bool = true
    minimizable*: bool = true
    maximizable*: bool = true
    borderless*: bool
    transparent*: bool
    alwaysOnTop*: bool
    hidden*: bool
    fullscreen*: bool
    acceptFirstMouse*: bool = true
    backgroundColor*: ZappColor
    numericIdPrealloc*: int32 = -1
    inspectable*: Inspectable = Inspectable.Inherit  # cascade: window > AppConfig > dev/prod
    frameAutosaveName*: string
    vibrancy*: Material
    # --- title-bar style + traffic-light buttons ---
    # titleBarStyle MUST be explicit: Unset is ord 3 (appended last), NOT the
    # enum's zero value (Default=0). Without `= TitleBarStyle.Unset` an
    # unspecified titleBarStyle would default to Default and re-break the
    # split-window title-bar logic (window.m only applies the sidebar chrome
    # default for tbs==3/Unset).
    titleBarStyle*: TitleBarStyle = TitleBarStyle.Unset
    trafficLights*: TrafficLights = TrafficLights(
      close: ButtonState.Enabled, minimize: ButtonState.Enabled, zoom: ButtonState.Enabled)
    # --- accessory chrome (nested; "" url / empty items ⇒ never built) -------
    # Sidebar/inspector geometry defaults MUST stay non-zero: window.m sets
    # NSSplitViewItem.maximumThickness = wopts_sidebar_max_width(opts) literally,
    # so a 0 default clamps the pane to ZERO width (invisible sidebar — #460).
    # Those non-zero defaults are now carried by SidebarOptions/InspectorOptions.
    backgroundExtension*: BackgroundExtension  ## macOS 26+: content bg vs floating sidebar
    sidebar*: SidebarOptions
    inspector*: InspectorOptions
    toolbar*: ToolbarOptions
    toolbarJsonCache*: string   ## derived: wopts_toolbar_json serializes `toolbar` here
                                ## so the returned cstring borrows a GC-pinned buffer (BOUNDARY RULE 1)
    # --- runtime Window.create extras (JS-driven) ---
    asSheetOfId*: int32 = -1
    sheetPresentation*: int32
    sheetDetents*: int32
    sheetGrabber*: bool
    # --- iOS native routing (N3a) ---
    nativeRouting*: bool = false


# Resolve a per-window Inspectable to the effective bool. Cascade:
#   On/Off → forced; Auto → dev-tools flag; Inherit → AppConfig's resolution
#   (app On/Off forced, app Auto/Inherit → dev-tools flag). Mirrors zc's intent.
proc zapp_build_dev_tools_default(): cint {.importc, cdecl.}
proc resolveInspectable*(w: Inspectable): bool =
  case w
  of Inspectable.On: true
  of Inspectable.Off: false
  of Inspectable.Auto: zapp_build_dev_tools_default() > 0
  of Inspectable.Inherit: app_get_bootstrap_web_content_inspectable()

template opt(p: pointer): WindowOptions = cast[WindowOptions](p)

# Enum→value lookup tables, derived once from the enum's own $ values (single
# source of truth). Module-global + never reassigned ⇒ a borrowed cstring stays
# valid for window.m's synchronous read.
let materialStr = (block:
  var a: array[Material, string]
  for m in Material: a[m] = $m
  a)
let sidebarPresStr = (block:
  var a: array[SidebarPresentation, string]
  for p in SidebarPresentation: a[p] = $p
  a)
let backgroundExtensionStr = [BackgroundExtension.None: "none", BackgroundExtension.Extend: "extend", BackgroundExtension.Mirror: "mirror"]

# Generic string→enum: returns the member whose $ equals `s`, else `dflt`.
# (The "" Default/sentinel member is itself matchable, so `s == ""` returns it.)
proc enumFromStr[T: enum](s: string, dflt: T): T =
  for e in T:
    if $e == s: return e
  dflt

# --- wopts_* C-ABI accessors (read by window.m) -----------------------------
# Signatures match native/platform/darwin/window.h + the externs in window.m.
# char*/const char* both map to Nim `cstring`. Returning `o.field.cstring`
# borrows the ref's GC-owned buffer; the ref is GC_ref'd for window.m's whole
# synchronous read, so the pointer stays live (BOUNDARY RULE 1).

proc wopts_title(p: pointer): cstring {.exportc, cdecl.} = opt(p).title.cstring
proc wopts_url(p: pointer): cstring {.exportc, cdecl.} = opt(p).url.cstring
proc wopts_width(p: pointer): int32 {.exportc, cdecl.} = opt(p).width
proc wopts_height(p: pointer): int32 {.exportc, cdecl.} = opt(p).height
proc wopts_x(p: pointer): int32 {.exportc, cdecl.} = opt(p).x
proc wopts_y(p: pointer): int32 {.exportc, cdecl.} = opt(p).y
proc wopts_auto_center(p: pointer): bool {.exportc, cdecl.} = opt(p).autoCenter
proc wopts_visible(p: pointer): bool {.exportc, cdecl.} = opt(p).visible
proc wopts_resizable(p: pointer): bool {.exportc, cdecl.} = opt(p).resizable
proc wopts_closable(p: pointer): bool {.exportc, cdecl.} = opt(p).closable
proc wopts_minimizable(p: pointer): bool {.exportc, cdecl.} = opt(p).minimizable
proc wopts_maximizable(p: pointer): bool {.exportc, cdecl.} = opt(p).maximizable
proc wopts_fullscreen(p: pointer): bool {.exportc, cdecl.} = opt(p).fullscreen
proc wopts_borderless(p: pointer): bool {.exportc, cdecl.} = opt(p).borderless
proc wopts_transparent(p: pointer): bool {.exportc, cdecl.} = opt(p).transparent
proc wopts_hidden(p: pointer): bool {.exportc, cdecl.} = opt(p).hidden
proc wopts_always_on_top(p: pointer): bool {.exportc, cdecl.} = opt(p).alwaysOnTop
proc wopts_accept_first_mouse(p: pointer): bool {.exportc, cdecl.} = opt(p).acceptFirstMouse
proc wopts_background_color(p: pointer): cstring {.exportc, cdecl.} = string(opt(p).backgroundColor).cstring
proc wopts_numeric_id_pre_alloc(p: pointer): int32 {.exportc, cdecl.} = opt(p).numericIdPrealloc
proc wopts_inspectable(p: pointer): int32 {.exportc, cdecl.} =
  if resolveInspectable(opt(p).inspectable): 1 else: 0
proc wopts_frame_autosave_name(p: pointer): cstring {.exportc, cdecl.} = opt(p).frameAutosaveName.cstring
proc wopts_vibrancy(p: pointer): cstring {.exportc, cdecl.} = materialStr[opt(p).vibrancy].cstring
proc wopts_title_bar_style_tag(p: pointer): int32 {.exportc, cdecl.} = opt(p).titleBarStyle.int32
proc wopts_traffic_light_close_tag(p: pointer): int32 {.exportc, cdecl.} = opt(p).trafficLights.close.int32
proc wopts_traffic_light_minimize_tag(p: pointer): int32 {.exportc, cdecl.} = opt(p).trafficLights.minimize.int32
proc wopts_traffic_light_zoom_tag(p: pointer): int32 {.exportc, cdecl.} = opt(p).trafficLights.zoom.int32

proc wopts_background_extension(p: pointer): cstring {.exportc, cdecl.} =
  backgroundExtensionStr[opt(p).backgroundExtension].cstring

# sidebar accessors — unused feature; "" url short-circuits the sidebar branch.
proc wopts_sidebar_url(p: pointer): cstring {.exportc, cdecl.} = opt(p).sidebar.url.cstring
proc wopts_sidebar_material(p: pointer): cstring {.exportc, cdecl.} = materialStr[opt(p).sidebar.material].cstring
proc wopts_sidebar_width(p: pointer): int32 {.exportc, cdecl.} = opt(p).sidebar.width
proc wopts_sidebar_min_width(p: pointer): int32 {.exportc, cdecl.} = opt(p).sidebar.minWidth
proc wopts_sidebar_max_width(p: pointer): int32 {.exportc, cdecl.} = opt(p).sidebar.maxWidth
proc wopts_sidebar_collapsible(p: pointer): bool {.exportc, cdecl.} = opt(p).sidebar.collapsible
proc wopts_sidebar_collapsed(p: pointer): bool {.exportc, cdecl.} = opt(p).sidebar.collapsed
proc wopts_sidebar_can_resize(p: pointer): bool {.exportc, cdecl.} = opt(p).sidebar.resizable
proc wopts_sidebar_background_color(p: pointer): cstring {.exportc, cdecl.} = string(opt(p).sidebar.backgroundColor).cstring
proc wopts_sidebar_presentation(p: pointer): cstring {.exportc, cdecl.} = sidebarPresStr[opt(p).sidebar.presentation].cstring
proc wopts_sidebar_numeric_id(p: pointer): int32 {.exportc, cdecl.} = opt(p).sidebar.numericId

# inspector accessors — unused feature; "" url short-circuits the branch.
proc wopts_inspector_url(p: pointer): cstring {.exportc, cdecl.} = opt(p).inspector.url.cstring
proc wopts_inspector_material(p: pointer): cstring {.exportc, cdecl.} = materialStr[opt(p).inspector.material].cstring
proc wopts_inspector_width(p: pointer): int32 {.exportc, cdecl.} = opt(p).inspector.width
proc wopts_inspector_min_width(p: pointer): int32 {.exportc, cdecl.} = opt(p).inspector.minWidth
proc wopts_inspector_max_width(p: pointer): int32 {.exportc, cdecl.} = opt(p).inspector.maxWidth
proc wopts_inspector_collapsible(p: pointer): bool {.exportc, cdecl.} = opt(p).inspector.collapsible
proc wopts_inspector_collapsed(p: pointer): bool {.exportc, cdecl.} = opt(p).inspector.collapsed
proc wopts_inspector_can_resize(p: pointer): bool {.exportc, cdecl.} = opt(p).inspector.resizable
proc wopts_inspector_background_color(p: pointer): cstring {.exportc, cdecl.} = string(opt(p).inspector.backgroundColor).cstring
proc wopts_inspector_numeric_id(p: pointer): int32 {.exportc, cdecl.} = opt(p).inspector.numericId

# toolbar accessor — defined after the j* JSON helpers (serializeToolbar/
# parseToolbarJson depend on jHasStr/jStr/jHasBool/jBool), just before
# windowOptsApplyJson. C resolves wopts_toolbar_json by symbol name, so its
# position relative to window.m's extern doesn't matter.

# sheet accessors — read by ios/window.m's darwin_window_create to configure a
# UISheetPresentationController (presentation style, detents bitmask, grabber).
# macOS' darwin/window.m never reads these (sheets are a UIKit feature), so the
# macOS link doesn't reference them; the iOS link does, hence these {.exportc.}s.
# Mirror window.zc:316-318 (wopts_sheet_presentation/detents/grabber).
proc wopts_sheet_presentation(p: pointer): int32 {.exportc, cdecl.} = opt(p).sheetPresentation
proc wopts_sheet_detents(p: pointer): int32 {.exportc, cdecl.} = opt(p).sheetDetents
proc wopts_sheet_grabber(p: pointer): bool {.exportc, cdecl.} = opt(p).sheetGrabber

# --- Window creation --------------------------------------------------------
proc darwin_window_create(opts: pointer): pointer {.importc, cdecl.}
proc darwin_window_register_numeric_id(handle: pointer, id: int32) {.importc, cdecl.}
proc darwin_window_get_by_numeric_id(numericId: int32): pointer {.importc, cdecl.}
proc darwin_window_attach_modal(parent, modal: pointer) {.importc, cdecl.}
proc darwin_window_numeric_id_for_string(wid: cstring): int32 {.importc, cdecl.}
type
  Window* = object
    ## A created window — its monotonic numeric id + the opaque NSWindow* handle.
    ## Methods (`show`, `onReady`, …) hang off this so apps write `win.show()`,
    ## mirroring app.zc's `Window{id, handle}`.
    id*: int32
    handle*: pointer

var gNextWindowId: int32 = 0

proc createWindow*(o: WindowOptions): Window =
  ## Full WindowManager.create (port of window.zc:837-889). Allocate the window's
  ## numeric id, then — only when those panes are requested — the sidebar/inspector
  ## transport slots, all from the SAME monotonic id-space (never a parallel
  ## allocator, so a slot can never collide with a future window's id). asSheetOf
  ## forces visible=false (no free-floating flash) and attaches to the parent after
  ## create. Window lookups use the .m registry (no Nim handle map).
  let id = gNextWindowId
  inc gNextWindowId
  o.numericIdPrealloc = id
  if o.sidebar.url.len > 0:
    o.sidebar.numericId = gNextWindowId
    inc gNextWindowId
  if o.inspector.url.len > 0:
    o.inspector.numericId = gNextWindowId
    inc gNextWindowId
  if o.asSheetOfId >= 0:
    o.visible = false
  # window.m reads `o` ONLY synchronously inside darwin_window_create via the
  # wopts_* accessors; pin across the call so ORC can't collect mid-read, then
  # unpin (the createWindow pin/unpin template).
  GC_ref(o)
  let h = darwin_window_create(cast[pointer](o))
  GC_unref(o)
  darwin_window_register_numeric_id(h, id)
  if o.asSheetOfId >= 0:
    let parent = darwin_window_get_by_numeric_id(o.asSheetOfId)
    if parent != nil:
      darwin_window_attach_modal(parent, h)
  # Seed the router state for this window at "/" (the app can replace it on
  # the first route push). Idempotent — routerSeed no-ops if already present.
  routerSeed(id, "/")
  gNativeRouting[id] = o.nativeRouting   # N3a: stash the nativeRouting flag for ios/routing.m
  Window(id: id, handle: h)

proc zapp_router_clear_window*(numericId: int32) {.exportc, cdecl.} =
  ## Called from darwin_window_destroy (window.m) to free the route state for
  ## a destroyed window. Exported as a C symbol so window.m can call it without
  ## a Nim-level import cycle.
  routerClear(numericId)

proc allocSlot*(): int32 =
  ## Draw one dispatch slot from the same monotonic id-space windows + panes use
  ## (port of window.zc:894-898 alloc_slot). Used by the router's __popover:create.
  result = gNextWindowId
  inc gNextWindowId

proc create*(wm: WindowManager, o: WindowOptions): Window =
  ## app.window.create(opts) — mirrors zc app.window.create. Delegates to the
  ## createWindow primitive (also used directly by the router for __window:create).
  createWindow(o)

# --- on-ready + show (port of Window.on_ready / Window.show) -----------------
# The webview posts {t:4,m:"ready"} once its bootstrap bridge is up; the router
# calls zapp_window_trigger_on_ready (router.nim:485), which invokes the cb the
# app registered. `zapp_window_set_on_ready` is a C symbol from callbacks.nim
# (exportc, NOT a Nim `*` export), so we reach it by importc — the same pattern
# router.nim uses for zapp_window_trigger_on_ready / zapp_window_set_close_guard.
type ReadyProc* = proc(id: cint, handle: pointer) {.cdecl.}
proc zapp_window_set_on_ready(id: cint, handle: pointer, cb: ReadyProc) {.importc, cdecl.}
proc darwin_window_show(handle: pointer) {.importc, cdecl.}

proc onReady*(win: Window, cb: ReadyProc) =
  ## Register `cb` to fire once the window's webview bridge is ready — the Nim
  ## analog of `win.on_ready(cb)` (mirrors zc `win.on_ready`). Pair with
  ## `opts.visible = false` to defer the first paint until content can render
  ## (no empty-window flash). `cb` must be a top-level `{.cdecl.}` proc taking
  ## `(id: cint, handle: pointer)`; reconstruct the window inside it with
  ## `Window(id: id, handle: handle).show()`.
  zapp_window_set_on_ready(win.id.cint, win.handle, cb)

proc show*(win: Window) =
  ## Show the window — `win.show()`, the Nim analog of `Window.show()`.
  darwin_window_show(win.handle)

# --- JSON → WindowOptions (port of window.zc:window_opts_apply_json) -----------
# nil-safe readers. Numeric reads use getFloat so a fractional dim from the bridge
# (which stores all JSON numbers as doubles) isn't silently truncated to 0 by the
# std/json getInt-on-JFloat trap.
proc jStr(a: JsonNode, k: string): string =
  let v = a{k}
  if not v.isNil and v.kind == JString: v.getStr else: ""
proc jHasStr(a: JsonNode, k: string): bool =
  let v = a{k}; (not v.isNil and v.kind == JString)
proc jI32(a: JsonNode, k: string, dflt: int32): int32 =
  let v = a{k}
  if v.isNil: dflt
  elif v.kind == JInt: v.getInt.int32
  elif v.kind == JFloat: v.getFloat.int32
  else: dflt
proc jHasNum(a: JsonNode, k: string): bool =
  let v = a{k}; (not v.isNil and (v.kind == JInt or v.kind == JFloat))
proc jBool(a: JsonNode, k: string, dflt: bool): bool =
  let v = a{k}
  if not v.isNil and v.kind == JBool: v.getBool else: dflt
proc jHasBool(a: JsonNode, k: string): bool =
  let v = a{k}; (not v.isNil and v.kind == JBool)
proc jHasInt(a: JsonNode, k: string): bool =
  let v = a{k}; (not v.isNil and v.kind == JInt)
proc jInt(a: JsonNode, k: string, d: int): int =
  let v = a{k}; (if v.isNil or v.kind != JInt: d else: v.getInt)

# Serialize ToolbarOptions to the native toolbar wire JSON ({style, items:[...]})
# consumed by toolbar.m's zapp_toolbar_parse_items (matches TS normalizeToolbar).
# Nim-vs-TS divergence (harmless): TS omits enabled/indicator when unset, whereas
# we always emit `enabled` on buttons and `indicator` on menu items. Native defaults
# both to YES when absent, so the emitted `true` is behaviorally identical — and the
# always-emit keeps parseToolbarJson(serializeToolbar(t)) a lossless round-trip.
proc serializeToolbar*(t: ToolbarOptions): string =
  var items = newJArray()
  for it in t.items:
    case it.`type`
    of "toggleSidebar", "toggleInspector", "space", "flexibleSpace":
      items.add(%*{"type": it.`type`})
    of "trackingSeparator":
      items.add(%*{"type": "trackingSeparator",
                   "pane": (if it.pane.len > 0: it.pane else: "sidebar")})
    of "segmented":
      var segs = newJArray()
      for sg in it.segments:
        var sj = newJObject()
        if sg.id.len > 0: sj["id"] = %sg.id
        if sg.label.len > 0: sj["label"] = %sg.label
        if sg.icon.len > 0: sj["icon"] = %sg.icon
        sj["enabled"] = %sg.enabled
        segs.add(sj)
      var w = %*{"type": "segmented", "id": it.id, "segments": segs,
                 "selectionMode": $it.selectionMode, "selected": %it.selected}
      if it.controlRepresentation != ToolbarControlRepresentation.Automatic:
        w["controlRepresentation"] = %($it.controlRepresentation)
      items.add(w)
    of "group":
      var subs = newJArray()
      for sub in it.items:
        subs.add(%*{"type": "button", "id": sub.id, "label": sub.label,
                    "icon": sub.icon, "enabled": sub.enabled})
        if not sub.bordered: subs[^1]["bordered"] = %false
      var w = %*{"type": "group", "id": it.id, "items": subs}
      if it.controlRepresentation != ToolbarControlRepresentation.Automatic:
        w["controlRepresentation"] = %($it.controlRepresentation)
      items.add(w)
    of "label":
      items.add(%*{"type": "label", "id": it.id, "text": it.text})
    else:  # button (default)
      var w = %*{"type": "button", "id": it.id, "label": it.label,
                 "icon": it.icon, "enabled": it.enabled}
      if it.style == ToolbarItemStyle.Prominent: w["style"] = %($it.style)
      if it.tintColor.len > 0: w["tintColor"] = %it.tintColor
      if not it.bordered: w["bordered"] = %false
      case it.badge.kind
      of ToolbarBadgeKind.Count: w["badge"] = %*{"kind": "count", "count": it.badge.count}
      of ToolbarBadgeKind.Text:  w["badge"] = %*{"kind": "text", "text": it.badge.text}
      of ToolbarBadgeKind.Dot:   w["badge"] = %*{"kind": "dot"}
      of ToolbarBadgeKind.None:  discard
      if it.menu.len > 0:
        var m = newJArray()
        for mi in it.menu:
          m.add(%*{"id": mi.id, "label": mi.label, "icon": mi.icon, "checked": mi.checked})
        w["menu"] = m
        w["indicator"] = %it.indicator   # chevron — only meaningful on menu items
      items.add(w)
    items[^1]["placement"] = %($it.placement)
  $(%*{"style": $t.style, "items": items})

# Inverse: parse a native toolbar wire string back into ToolbarOptions (used when
# a window arrives over the JSON wire carrying a pre-serialized toolbarJson string).
proc parseToolbarJson*(s: string): ToolbarOptions =
  result.style = ToolbarStyle.Unified
  if s.len == 0: return
  let root = try: parseJson(s) except CatchableError: return
  if root.kind != JObject: return
  if jHasStr(root, "style"): result.style = enumFromStr[ToolbarStyle](jStr(root, "style"), ToolbarStyle.Unified)
  let items = root{"items"}
  if items.isNil or items.kind != JArray: return
  for itn in items:
    if itn.kind != JObject: continue
    var item = ToolbarItemOpt(enabled: true, indicator: true)  # explicit: match field defaults
    item.`type` = (if jHasStr(itn, "type"): jStr(itn, "type") else: "button")
    if item.`type` == "segmented":
      if jHasStr(itn, "selectionMode"):
        item.selectionMode = enumFromStr[ToolbarGroupSelectionMode](jStr(itn, "selectionMode"), ToolbarGroupSelectionMode.Momentary)
      item.controlRepresentation = (if jHasStr(itn, "controlRepresentation"):
        enumFromStr[ToolbarControlRepresentation](jStr(itn, "controlRepresentation"), ToolbarControlRepresentation.Automatic)
        else: ToolbarControlRepresentation.Automatic)
      let seln = itn{"selected"}
      if not seln.isNil and seln.kind == JArray:
        for v in seln:
          if v.kind == JInt: item.selected.add(v.getInt)
      let segn = itn{"segments"}
      if not segn.isNil and segn.kind == JArray:
        for sn in segn:
          if sn.kind != JObject: continue
          var sg = ToolbarSegmentOpt(enabled: true)
          if jHasStr(sn, "id"): sg.id = jStr(sn, "id")
          if jHasStr(sn, "label"): sg.label = jStr(sn, "label")
          if jHasStr(sn, "icon"): sg.icon = jStr(sn, "icon")
          if jHasBool(sn, "enabled"): sg.enabled = jBool(sn, "enabled", true)
          item.segments.add(sg)
    if item.`type` == "group":
      item.controlRepresentation = (if jHasStr(itn, "controlRepresentation"):
        enumFromStr[ToolbarControlRepresentation](jStr(itn, "controlRepresentation"), ToolbarControlRepresentation.Automatic)
        else: ToolbarControlRepresentation.Automatic)
      let subn = itn{"items"}
      if not subn.isNil and subn.kind == JArray:
        for sn in subn:
          if sn.kind != JObject: continue
          var sub = ToolbarItemOpt(`type`: "button", enabled: true, indicator: true, bordered: true)
          if jHasStr(sn, "id"): sub.id = jStr(sn, "id")
          if jHasStr(sn, "label"): sub.label = jStr(sn, "label")
          if jHasStr(sn, "icon"): sub.icon = jStr(sn, "icon")
          if jHasBool(sn, "enabled"): sub.enabled = jBool(sn, "enabled", true)
          if jHasBool(sn, "bordered"): sub.bordered = jBool(sn, "bordered", true)
          item.items.add(sub)
    if jHasStr(itn, "id"): item.id = jStr(itn, "id")
    if jHasStr(itn, "pane"): item.pane = jStr(itn, "pane")
    if jHasStr(itn, "label"): item.label = jStr(itn, "label")
    if jHasStr(itn, "icon"): item.icon = jStr(itn, "icon")
    if item.`type` == "label":
      if jHasStr(itn, "text"): item.text = jStr(itn, "text")
    if jHasBool(itn, "enabled"): item.enabled = jBool(itn, "enabled", true)
    if jHasBool(itn, "indicator"): item.indicator = jBool(itn, "indicator", true)
    if jHasStr(itn, "style"): item.style = enumFromStr[ToolbarItemStyle](jStr(itn, "style"), ToolbarItemStyle.Plain)
    if jHasStr(itn, "tintColor"): item.tintColor = jStr(itn, "tintColor")
    item.bordered = (if jHasBool(itn, "bordered"): jBool(itn, "bordered", true) else: true)
    let bn = itn{"badge"}
    if not bn.isNil and bn.kind == JObject:
      let bk = if jHasStr(bn, "kind"): jStr(bn, "kind") else: "none"
      case bk
      of "count": item.badge = ToolbarBadge(kind: ToolbarBadgeKind.Count, count: (if jHasInt(bn, "count"): jInt(bn, "count", 0) else: 0))
      of "text":  item.badge = ToolbarBadge(kind: ToolbarBadgeKind.Text, text: (if jHasStr(bn, "text"): jStr(bn, "text") else: ""))
      of "dot":   item.badge = ToolbarBadge(kind: ToolbarBadgeKind.Dot)
      else:       item.badge = ToolbarBadge(kind: ToolbarBadgeKind.None)
    let menu = itn{"menu"}
    if not menu.isNil and menu.kind == JArray:
      for mn in menu:
        if mn.kind != JObject: continue
        var m: MenuItemOpt
        if jHasStr(mn, "id"): m.id = jStr(mn, "id")
        if jHasStr(mn, "label"): m.label = jStr(mn, "label")
        if jHasStr(mn, "icon"): m.icon = jStr(mn, "icon")
        if jHasBool(mn, "checked"): m.checked = jBool(mn, "checked", false)
        item.menu.add(m)
    item.placement = (if jHasStr(itn, "placement"):
      enumFromStr[ToolbarPlacement](jStr(itn, "placement"), ToolbarPlacement.Leading)
      else: ToolbarPlacement.Leading)
    result.items.add(item)

# toolbar accessor — serializes `toolbar` into the ref's own toolbarJsonCache so
# the returned cstring borrows a GC-pinned buffer (BOUNDARY RULE 1). Empty items
# ⇒ "" ⇒ window.m skips darwin_toolbar_attach (same short-circuit as the old flat field).
proc wopts_toolbar_json(p: pointer): cstring {.exportc, cdecl.} =
  let o = opt(p)
  o.toolbarJsonCache = (if o.toolbar.items.len == 0: "" else: serializeToolbar(o.toolbar))
  o.toolbarJsonCache.cstring

proc buttonStateFromStr(s: string, dflt: ButtonState): ButtonState =
  case s
  of "hidden": ButtonState.Hidden
  of "disabled": ButtonState.Disabled
  of "enabled": ButtonState.Enabled
  else: dflt

proc windowOptsApplyJson*(o: WindowOptions, a: JsonNode) =
  ## Set each WindowOptions field from the JSON args when present. Missing keys
  ## leave the type's field defaults. Faithful to window_opts_apply_json
  ## (incl. closable/minimizable/maximizable=false disabling the matching
  ## traffic-light button, and asSheetOf accepting a number or a "win-<n>" string).
  if a.isNil or a.kind != JObject: return
  if jHasStr(a, "title"): o.title = jStr(a, "title")
  if jHasStr(a, "url"): o.url = jStr(a, "url")
  if jHasNum(a, "width"): o.width = jI32(a, "width", o.width)
  if jHasNum(a, "height"): o.height = jI32(a, "height", o.height)
  if jHasNum(a, "x"): o.x = jI32(a, "x", o.x)
  if jHasNum(a, "y"): o.y = jI32(a, "y", o.y)
  if jHasBool(a, "visible"): o.visible = jBool(a, "visible", o.visible)
  if jHasBool(a, "resizable"): o.resizable = jBool(a, "resizable", o.resizable)
  if jHasBool(a, "closable"):
    o.closable = jBool(a, "closable", o.closable)
    if not o.closable: o.trafficLights.close = ButtonState.Disabled
  if jHasBool(a, "minimizable"):
    o.minimizable = jBool(a, "minimizable", o.minimizable)
    if not o.minimizable: o.trafficLights.minimize = ButtonState.Disabled
  if jHasBool(a, "maximizable"):
    o.maximizable = jBool(a, "maximizable", o.maximizable)
    if not o.maximizable: o.trafficLights.zoom = ButtonState.Disabled
  if jHasBool(a, "fullscreen"): o.fullscreen = jBool(a, "fullscreen", o.fullscreen)
  if jHasBool(a, "borderless"): o.borderless = jBool(a, "borderless", o.borderless)
  if jHasBool(a, "transparent"): o.transparent = jBool(a, "transparent", o.transparent)
  if jHasBool(a, "hidden"): o.hidden = jBool(a, "hidden", o.hidden)
  if jHasBool(a, "alwaysOnTop"): o.alwaysOnTop = jBool(a, "alwaysOnTop", o.alwaysOnTop)
  if jHasBool(a, "acceptFirstMouse"): o.acceptFirstMouse = jBool(a, "acceptFirstMouse", o.acceptFirstMouse)
  if jHasBool(a, "autoCenter"): o.autoCenter = jBool(a, "autoCenter", o.autoCenter)
  if jHasStr(a, "vibrancy"): o.vibrancy = enumFromStr[Material](jStr(a, "vibrancy"), Material.Default)
  if jHasStr(a, "backgroundExtension"):
    o.backgroundExtension = enumFromStr[BackgroundExtension](jStr(a, "backgroundExtension"), BackgroundExtension.None)
  if jHasStr(a, "backgroundColor"): o.backgroundColor = jStr(a, "backgroundColor")
  if jHasStr(a, "frameAutosaveName"): o.frameAutosaveName = jStr(a, "frameAutosaveName")
  if jHasStr(a, "toolbarJson"): o.toolbar = parseToolbarJson(jStr(a, "toolbarJson"))
  let sb = a{"sidebar"}
  if not sb.isNil and sb.kind == JObject:
    if jHasStr(sb, "url"): o.sidebar.url = jStr(sb, "url")
    if jHasStr(sb, "material"): o.sidebar.material = enumFromStr[Material](jStr(sb, "material"), Material.Default)
    if jHasStr(sb, "backgroundColor"): o.sidebar.backgroundColor = jStr(sb, "backgroundColor")
    if jHasNum(sb, "width"): o.sidebar.width = jI32(sb, "width", o.sidebar.width)
    if jHasNum(sb, "minWidth"): o.sidebar.minWidth = jI32(sb, "minWidth", o.sidebar.minWidth)
    if jHasNum(sb, "maxWidth"): o.sidebar.maxWidth = jI32(sb, "maxWidth", o.sidebar.maxWidth)
    if jHasBool(sb, "collapsible"): o.sidebar.collapsible = jBool(sb, "collapsible", o.sidebar.collapsible)
    if jHasBool(sb, "collapsed"): o.sidebar.collapsed = jBool(sb, "collapsed", o.sidebar.collapsed)
    if jHasBool(sb, "resizable"): o.sidebar.resizable = jBool(sb, "resizable", o.sidebar.resizable)
    if jHasStr(sb, "presentation"): o.sidebar.presentation = enumFromStr[SidebarPresentation](jStr(sb, "presentation"), SidebarPresentation.Default)
  let insp = a{"inspector"}
  if not insp.isNil and insp.kind == JObject:
    if jHasStr(insp, "url"): o.inspector.url = jStr(insp, "url")
    if jHasStr(insp, "material"): o.inspector.material = enumFromStr[Material](jStr(insp, "material"), Material.Default)
    if jHasStr(insp, "backgroundColor"): o.inspector.backgroundColor = jStr(insp, "backgroundColor")
    if jHasNum(insp, "width"): o.inspector.width = jI32(insp, "width", o.inspector.width)
    if jHasNum(insp, "minWidth"): o.inspector.minWidth = jI32(insp, "minWidth", o.inspector.minWidth)
    if jHasNum(insp, "maxWidth"): o.inspector.maxWidth = jI32(insp, "maxWidth", o.inspector.maxWidth)
    if jHasBool(insp, "collapsible"): o.inspector.collapsible = jBool(insp, "collapsible", o.inspector.collapsible)
    if jHasBool(insp, "collapsed"): o.inspector.collapsed = jBool(insp, "collapsed", o.inspector.collapsed)
    if jHasBool(insp, "resizable"): o.inspector.resizable = jBool(insp, "resizable", o.inspector.resizable)
  let aso = a{"asSheetOf"}
  if not aso.isNil:
    if aso.kind == JInt or aso.kind == JFloat:
      o.asSheetOfId = jI32(a, "asSheetOf", o.asSheetOfId)
    elif aso.kind == JString:
      # Resolve "win-<n>" via the .m registry (returns -1 for an unknown window),
      # matching window_opts_apply_json (window.zc:519-531) and the router's path.
      o.asSheetOfId = darwin_window_numeric_id_for_string(aso.getStr.cstring)
  let pres = jStr(a, "presentation")
  case pres
  of "page": o.sheetPresentation = 0
  of "form": o.sheetPresentation = 1
  of "fullscreen": o.sheetPresentation = 2
  of "bottomSheet": o.sheetPresentation = 3
  else: discard
  let detents = a{"detents"}
  if not detents.isNil and detents.kind == JArray:
    var bits: int32 = 0
    for d in detents:
      if d.kind == JString:
        case d.getStr
        of "small": bits = bits or 4
        of "medium": bits = bits or 1
        of "large": bits = bits or 2
        else: discard
    o.sheetDetents = bits
  if jHasBool(a, "grabber"): o.sheetGrabber = jBool(a, "grabber", o.sheetGrabber)
  if jHasBool(a, "nativeRouting"): o.nativeRouting = jBool(a, "nativeRouting", o.nativeRouting)
  let tbs = jStr(a, "titleBarStyle")
  case tbs
  of "hidden": o.titleBarStyle = TitleBarStyle.Hidden
  of "hiddenInset": o.titleBarStyle = TitleBarStyle.HiddenInset
  of "default": o.titleBarStyle = TitleBarStyle.Default
  else: discard
  let tl = a{"trafficLights"}
  if not tl.isNil and tl.kind == JObject:
    if jHasStr(tl, "close"): o.trafficLights.close = buttonStateFromStr(jStr(tl, "close"), ButtonState.Enabled)
    if jHasStr(tl, "minimize"): o.trafficLights.minimize = buttonStateFromStr(jStr(tl, "minimize"), ButtonState.Enabled)
    if jHasStr(tl, "zoom"): o.trafficLights.zoom = buttonStateFromStr(jStr(tl, "zoom"), ButtonState.Enabled)

