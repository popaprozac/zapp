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

type
  TitleBarStyle* {.pure.} = enum   ## NSWindow title-bar style (window.m tag 0/1/2)
    Default = 0
    Hidden = 1
    HiddenInset = 2

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
    sidebarWidth*, sidebarMinWidth*, sidebarMaxWidth*: int32
    sidebarCollapsible*, sidebarCollapsed*: bool
    sidebarNumericId*: int32
    # --- inspector pane (feature unused; "" url => never built) ---
    inspectorUrl*: string
    inspectorMaterial*: string
    inspectorWidth*, inspectorMinWidth*, inspectorMaxWidth*: int32
    inspectorCollapsible*, inspectorCollapsed*: bool
    inspectorNumericId*: int32
    # --- toolbar (feature unused; "" json => never attached) ---
    toolbarJson*: string

proc newWindowOptions*(title: string): WindowOptions =
  ## Mirrors WindowOptions::new — sane macOS window defaults.
  WindowOptions(
    title: title,
    url: "",
    width: 1200, height: 800,
    x: 0, y: 0,
    autoCenter: true,
    visible: true,
    resizable: true, closable: true, minimizable: true, maximizable: true,
    borderless: false, transparent: false, alwaysOnTop: false,
    hidden: false, fullscreen: false, acceptFirstMouse: false,
    backgroundColor: "",
    numericIdPrealloc: -1,
    inspectable: TriState.Unset,
    frameAutosaveName: "",
    vibrancy: "",
    titleBarStyle: TitleBarStyle.Default,
    trafficLights: TrafficLights(close: ButtonState.Enabled,
                                 minimize: ButtonState.Enabled,
                                 zoom: ButtonState.Enabled),
    sidebarUrl: "", sidebarMaterial: "",
    sidebarWidth: 0, sidebarMinWidth: 0, sidebarMaxWidth: 0,
    sidebarCollapsible: false, sidebarCollapsed: false, sidebarNumericId: -1,
    inspectorUrl: "", inspectorMaterial: "",
    inspectorWidth: 0, inspectorMinWidth: 0, inspectorMaxWidth: 0,
    inspectorCollapsible: false, inspectorCollapsed: false, inspectorNumericId: -1,
    toolbarJson: "",
  )

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
proc wopts_sidebar_numeric_id(p: pointer): int32 {.exportc, cdecl.} = opt(p).sidebarNumericId

# inspector accessors — unused feature; "" url short-circuits the branch.
proc wopts_inspector_url(p: pointer): cstring {.exportc, cdecl.} = opt(p).inspectorUrl.cstring
proc wopts_inspector_material(p: pointer): cstring {.exportc, cdecl.} = opt(p).inspectorMaterial.cstring
proc wopts_inspector_width(p: pointer): int32 {.exportc, cdecl.} = opt(p).inspectorWidth
proc wopts_inspector_min_width(p: pointer): int32 {.exportc, cdecl.} = opt(p).inspectorMinWidth
proc wopts_inspector_max_width(p: pointer): int32 {.exportc, cdecl.} = opt(p).inspectorMaxWidth
proc wopts_inspector_collapsible(p: pointer): bool {.exportc, cdecl.} = opt(p).inspectorCollapsible
proc wopts_inspector_collapsed(p: pointer): bool {.exportc, cdecl.} = opt(p).inspectorCollapsed
proc wopts_inspector_numeric_id(p: pointer): int32 {.exportc, cdecl.} = opt(p).inspectorNumericId

# toolbar accessor — unused feature; "" json short-circuits darwin_toolbar_attach.
proc wopts_toolbar_json(p: pointer): cstring {.exportc, cdecl.} = opt(p).toolbarJson.cstring

# --- Window creation --------------------------------------------------------
proc darwin_window_create(opts: pointer): pointer {.importc, cdecl.}
proc darwin_window_register_numeric_id(handle: pointer, id: int32) {.importc, cdecl.}

var gNextWindowId: int32 = 0

proc createWindow*(o: WindowOptions): tuple[id: int32, handle: pointer] =
  ## Allocate the next numeric id, hand the opaque options to window.m, and
  ## register the id against the returned NSWindow/WKWebView handle.
  let id = gNextWindowId
  inc gNextWindowId
  o.numericIdPrealloc = id
  # window.m reads `o` ONLY synchronously inside darwin_window_create (via the
  # wopts_* accessors); it copies what it needs (e.g. auto-show flags) into the
  # window delegate and never retains the pointer (verified: window.m:307/335).
  # Pin across the call so ORC can't collect mid-read, then unpin — no leak.
  # This pin/unpin pairing is the template for every module that hands a Nim ref
  # to the .m layer (do NOT leave a bare GC_ref dangling at breadth).
  GC_ref(o)
  let h = darwin_window_create(cast[pointer](o))
  GC_unref(o)
  darwin_window_register_numeric_id(h, id)
  (id, h)
