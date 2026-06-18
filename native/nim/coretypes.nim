## Shared cross-module atoms for the Nim native layer — the genuinely-reused
## enums more than one module needs. Per the type-modeling convention
## (docs/superpowers/specs/2026-06-15-nim-type-modeling-convention-design.md):
## named {.pure.} enums replace magic numbers; explicit ordinals match the C-ABI
## wire value (flatten with `.int32`/`.cint` at the boundary); the module is the
## namespace. Feature-specific enums live in their OWNING module — only
## genuinely-shared atoms belong here.

type
  Inspectable* {.pure.} = enum
    ## Web-inspector enablement, used by both AppConfig (app-wide) and
    ## WindowOptions (per-window) and resolved as a cascade
    ## (window-explicit > AppConfig > dev-vs-prod default).
    Inherit   ## defer to the level above (window → AppConfig); app-level Inherit == Auto
    Auto      ## decide by build: dev-tools flag on → on, else off
    On        ## force on
    Off       ## force off

  EventResult* {.pure.} = enum
    ## A window-event dispatch verdict (callbacks.nim zapp_dispatch_event,
    ## mirroring the zc events.zc EventResult): Allow lets the native action
    ## proceed; Cancel stops it.
    Allow  = 0
    Cancel = 1
