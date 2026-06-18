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
export coretypes   # WindowOptions.inspectable is a coretypes.TriState
import std/json
import apptypes
export apptypes    # WindowManager visible to callers of window.nim

type
  TitleBarStyle* {.pure.} = enum   ## NSWindow title-bar style (window.m tag 0/1/2/3)
    Default = 0
    Hidden = 1
    HiddenInset = 2
    ## Unset = "app didn't pick a style; use the chrome default" — distinct from
    ## Default (explicit "standard title bar"). On a sidebar/inspector window only
    ## Unset gets the unified hidden-title chrome default; an explicit Default
    ## opts back into a standard title bar. Mirrors zc's TitleBarStyle + the
    ## inspectable TriState (Unset/Off/On). Appended last to keep tags 0/1/2.
    Unset = 3

  ButtonState* {.pure.} = enum      ## a traffic-light button (window.m tag 0/1/2)
    Enabled = 0
    Disabled = 1
    Hidden = 2

  TrafficLights* = object           ## the three window buttons (zc TrafficLights struct)
    close*, minimize*, zoom*: ButtonState

  WindowOptions* = ref object
    # --- set by the skeleton ---
    title*: string
    url*: string
    width*, height*: int32
    x*, y*: int32
    autoCenter*: bool
    visible*: bool
    resizable*: bool
    closable*: bool
    minimizable*: bool
    maximizable*: bool
    borderless*: bool
    transparent*: bool
    alwaysOnTop*: bool
    hidden*: bool
    fullscreen*: bool
    acceptFirstMouse*: bool
    backgroundColor*: string
    numericIdPrealloc*: int32
    inspectable*: TriState        # unset/off/on; window.m treats `> 0` as on
    frameAutosaveName*: string
    vibrancy*: string
    # --- title-bar style + traffic-light buttons ---
    titleBarStyle*: TitleBarStyle
    trafficLights*: TrafficLights
    # --- sidebar (feature unused by the skeleton; "" url => never built) ---
    sidebarUrl*: string
    sidebarMaterial*: string
    sidebarBackgroundColor*: string
    sidebarWidth*, sidebarMinWidth*, sidebarMaxWidth*: int32
    sidebarCollapsible*, sidebarCollapsed*: bool
    sidebarCanResize*: bool
    sidebarNumericId*: int32
    # --- inspector pane (feature unused; "" url => never built) ---
    inspectorUrl*: string
    inspectorMaterial*: string
    inspectorBackgroundColor*: string
    inspectorWidth*, inspectorMinWidth*, inspectorMaxWidth*: int32
    inspectorCollapsible*, inspectorCollapsed*: bool
    inspectorCanResize*: bool
    inspectorNumericId*: int32
    # --- toolbar (feature unused; "" json => never attached) ---
    toolbarJson*: string
    # --- runtime Window.create extras (JS-driven; the skeleton boot never sets these) ---
    asSheetOfId*: int32          # -1 = not a sheet; else parent window numeric id
    sheetPresentation*: int32    # iOS sheet style 0=page/1=form/2=fullscreen/3=bottomSheet (macOS no-op)
    sheetDetents*: int32         # iOS bottomSheet detent bitmask (macOS no-op)
    sheetGrabber*: bool          # iOS sheet grabber (macOS no-op)

proc newWindowOptions*(title: string): WindowOptions =
  ## Mirrors WindowOptions::new — sane macOS window defaults.
  WindowOptions(
    title: title,
    url: "",
    width: 1200, height: 800,
    x: 0, y: 0,
    autoCenter: false,
    visible: true,
    resizable: true, closable: true, minimizable: true, maximizable: true,
    borderless: false, transparent: false, alwaysOnTop: false,
    hidden: false, fullscreen: false, acceptFirstMouse: true,
    backgroundColor: "",
    numericIdPrealloc: -1,
    inspectable: TriState.Unset,
    frameAutosaveName: "",
    vibrancy: "",
    titleBarStyle: TitleBarStyle.Unset,
    trafficLights: TrafficLights(close: ButtonState.Enabled,
                                 minimize: ButtonState.Enabled,
                                 zoom: ButtonState.Enabled),
    # Sidebar/inspector geometry defaults MUST mirror zc WindowOptions::create
    # (window.zc:229-246). window.m sets NSSplitViewItem.maximumThickness =
    # wopts_sidebar_max_width(opts) literally — a 0 default constrains the pane to
    # ZERO width (invisible sidebar), and collapsible:false disables the toolbar's
    # Hide-Sidebar/inspector toggle. These bit the first app.nim chrome-shell smoke
    # (sidebar absent) + the inspector-toggle bug (#460, inspectorMaxWidth 0).
    sidebarUrl: "", sidebarMaterial: "", sidebarBackgroundColor: "",
    sidebarWidth: 260, sidebarMinWidth: 180, sidebarMaxWidth: 400,
    sidebarCollapsible: true, sidebarCollapsed: false, sidebarCanResize: true,
    sidebarNumericId: -1,
    inspectorUrl: "", inspectorMaterial: "", inspectorBackgroundColor: "",
    inspectorWidth: 280, inspectorMinWidth: 180, inspectorMaxWidth: 400,
    inspectorCollapsible: true, inspectorCollapsed: false, inspectorCanResize: true,
    inspectorNumericId: -1,
    toolbarJson: "",
    asSheetOfId: -1,
    sheetPresentation: 0, sheetDetents: 0, sheetGrabber: false,
  )

# Web-inspector dev gate: resolve the CLI-emitted dev-tools flag (1 in dev, 0 in
# prod, generated into .zapp/) to a per-window TriState. Lets an app write
# `opts.inspectable = inspectableAuto()` without redeclaring the C-ABI importc.
proc zapp_build_dev_tools_default(): cint {.importc, cdecl.}
proc inspectableAuto*(): TriState =
  ## Web Inspector on in dev, off in prod — the Nim analog of
  ## `Zapp::inspectable_auto()`. Assign to `WindowOptions.inspectable`.
  if zapp_build_dev_tools_default() > 0: TriState.On else: TriState.Off

template opt(p: pointer): WindowOptions = cast[WindowOptions](p)

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
proc wopts_background_color(p: pointer): cstring {.exportc, cdecl.} = opt(p).backgroundColor.cstring
proc wopts_numeric_id_pre_alloc(p: pointer): int32 {.exportc, cdecl.} = opt(p).numericIdPrealloc
proc wopts_inspectable(p: pointer): int32 {.exportc, cdecl.} = opt(p).inspectable.int32
proc wopts_frame_autosave_name(p: pointer): cstring {.exportc, cdecl.} = opt(p).frameAutosaveName.cstring
proc wopts_vibrancy(p: pointer): cstring {.exportc, cdecl.} = opt(p).vibrancy.cstring
proc wopts_title_bar_style_tag(p: pointer): int32 {.exportc, cdecl.} = opt(p).titleBarStyle.int32
proc wopts_traffic_light_close_tag(p: pointer): int32 {.exportc, cdecl.} = opt(p).trafficLights.close.int32
proc wopts_traffic_light_minimize_tag(p: pointer): int32 {.exportc, cdecl.} = opt(p).trafficLights.minimize.int32
proc wopts_traffic_light_zoom_tag(p: pointer): int32 {.exportc, cdecl.} = opt(p).trafficLights.zoom.int32

# sidebar accessors — unused feature; "" url short-circuits the sidebar branch.
proc wopts_sidebar_url(p: pointer): cstring {.exportc, cdecl.} = opt(p).sidebarUrl.cstring
proc wopts_sidebar_material(p: pointer): cstring {.exportc, cdecl.} = opt(p).sidebarMaterial.cstring
proc wopts_sidebar_width(p: pointer): int32 {.exportc, cdecl.} = opt(p).sidebarWidth
proc wopts_sidebar_min_width(p: pointer): int32 {.exportc, cdecl.} = opt(p).sidebarMinWidth
proc wopts_sidebar_max_width(p: pointer): int32 {.exportc, cdecl.} = opt(p).sidebarMaxWidth
proc wopts_sidebar_collapsible(p: pointer): bool {.exportc, cdecl.} = opt(p).sidebarCollapsible
proc wopts_sidebar_collapsed(p: pointer): bool {.exportc, cdecl.} = opt(p).sidebarCollapsed
proc wopts_sidebar_can_resize(p: pointer): bool {.exportc, cdecl.} = opt(p).sidebarCanResize
proc wopts_sidebar_background_color(p: pointer): cstring {.exportc, cdecl.} = opt(p).sidebarBackgroundColor.cstring
proc wopts_sidebar_numeric_id(p: pointer): int32 {.exportc, cdecl.} = opt(p).sidebarNumericId

# inspector accessors — unused feature; "" url short-circuits the branch.
proc wopts_inspector_url(p: pointer): cstring {.exportc, cdecl.} = opt(p).inspectorUrl.cstring
proc wopts_inspector_material(p: pointer): cstring {.exportc, cdecl.} = opt(p).inspectorMaterial.cstring
proc wopts_inspector_width(p: pointer): int32 {.exportc, cdecl.} = opt(p).inspectorWidth
proc wopts_inspector_min_width(p: pointer): int32 {.exportc, cdecl.} = opt(p).inspectorMinWidth
proc wopts_inspector_max_width(p: pointer): int32 {.exportc, cdecl.} = opt(p).inspectorMaxWidth
proc wopts_inspector_collapsible(p: pointer): bool {.exportc, cdecl.} = opt(p).inspectorCollapsible
proc wopts_inspector_collapsed(p: pointer): bool {.exportc, cdecl.} = opt(p).inspectorCollapsed
proc wopts_inspector_can_resize(p: pointer): bool {.exportc, cdecl.} = opt(p).inspectorCanResize
proc wopts_inspector_background_color(p: pointer): cstring {.exportc, cdecl.} = opt(p).inspectorBackgroundColor.cstring
proc wopts_inspector_numeric_id(p: pointer): int32 {.exportc, cdecl.} = opt(p).inspectorNumericId

# toolbar accessor — unused feature; "" json short-circuits darwin_toolbar_attach.
proc wopts_toolbar_json(p: pointer): cstring {.exportc, cdecl.} = opt(p).toolbarJson.cstring

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
  if o.sidebarUrl.len > 0:
    o.sidebarNumericId = gNextWindowId
    inc gNextWindowId
  if o.inspectorUrl.len > 0:
    o.inspectorNumericId = gNextWindowId
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
  Window(id: id, handle: h)

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

proc buttonStateFromStr(s: string, dflt: ButtonState): ButtonState =
  case s
  of "hidden": ButtonState.Hidden
  of "disabled": ButtonState.Disabled
  of "enabled": ButtonState.Enabled
  else: dflt

proc windowOptsApplyJson*(o: WindowOptions, a: JsonNode) =
  ## Set each WindowOptions field from the JSON args when present. Missing keys
  ## leave the newWindowOptions defaults. Faithful to window_opts_apply_json
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
  if jHasStr(a, "vibrancy"): o.vibrancy = jStr(a, "vibrancy")
  if jHasStr(a, "backgroundColor"): o.backgroundColor = jStr(a, "backgroundColor")
  if jHasStr(a, "frameAutosaveName"): o.frameAutosaveName = jStr(a, "frameAutosaveName")
  if jHasStr(a, "toolbarJson"): o.toolbarJson = jStr(a, "toolbarJson")
  let sb = a{"sidebar"}
  if not sb.isNil and sb.kind == JObject:
    if jHasStr(sb, "url"): o.sidebarUrl = jStr(sb, "url")
    if jHasStr(sb, "material"): o.sidebarMaterial = jStr(sb, "material")
    if jHasStr(sb, "backgroundColor"): o.sidebarBackgroundColor = jStr(sb, "backgroundColor")
    if jHasNum(sb, "width"): o.sidebarWidth = jI32(sb, "width", o.sidebarWidth)
    if jHasNum(sb, "minWidth"): o.sidebarMinWidth = jI32(sb, "minWidth", o.sidebarMinWidth)
    if jHasNum(sb, "maxWidth"): o.sidebarMaxWidth = jI32(sb, "maxWidth", o.sidebarMaxWidth)
    if jHasBool(sb, "collapsible"): o.sidebarCollapsible = jBool(sb, "collapsible", o.sidebarCollapsible)
    if jHasBool(sb, "collapsed"): o.sidebarCollapsed = jBool(sb, "collapsed", o.sidebarCollapsed)
    if jHasBool(sb, "resizable"): o.sidebarCanResize = jBool(sb, "resizable", o.sidebarCanResize)
  let insp = a{"inspector"}
  if not insp.isNil and insp.kind == JObject:
    if jHasStr(insp, "url"): o.inspectorUrl = jStr(insp, "url")
    if jHasStr(insp, "material"): o.inspectorMaterial = jStr(insp, "material")
    if jHasStr(insp, "backgroundColor"): o.inspectorBackgroundColor = jStr(insp, "backgroundColor")
    if jHasNum(insp, "width"): o.inspectorWidth = jI32(insp, "width", o.inspectorWidth)
    if jHasNum(insp, "minWidth"): o.inspectorMinWidth = jI32(insp, "minWidth", o.inspectorMinWidth)
    if jHasNum(insp, "maxWidth"): o.inspectorMaxWidth = jI32(insp, "maxWidth", o.inspectorMaxWidth)
    if jHasBool(insp, "collapsible"): o.inspectorCollapsible = jBool(insp, "collapsible", o.inspectorCollapsible)
    if jHasBool(insp, "collapsed"): o.inspectorCollapsed = jBool(insp, "collapsed", o.inspectorCollapsed)
    if jHasBool(insp, "resizable"): o.inspectorCanResize = jBool(insp, "resizable", o.inspectorCanResize)
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
