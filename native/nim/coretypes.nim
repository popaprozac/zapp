## Shared cross-module atoms for the Nim native layer — the genuinely-reused
## enums more than one module needs. Per the type-modeling convention
## (docs/superpowers/specs/2026-06-15-nim-type-modeling-convention-design.md):
## named {.pure.} enums replace magic numbers; explicit ordinals match the C-ABI
## wire value (flatten with `.int32`/`.cint` at the boundary); the module is the
## namespace. Feature-specific enums live in their OWNING module — only
## genuinely-shared atoms belong here.

type
  TriState* {.pure.} = enum
    ## The recurring -1/0/1 tag: unset (inherit) / off / on. Used by the window
    ## `inspectable` tag (and, later, the webview prefs). window.m reads the
    ## ordinal and treats `> 0` as on, so Unset and Off are both "not on".
    Unset = -1
    Off   = 0
    On    = 1

  EventResult* {.pure.} = enum
    ## A window-event dispatch verdict (callbacks.nim zapp_dispatch_event,
    ## mirroring the zc events.zc EventResult): Allow lets the native action
    ## proceed; Cancel stops it.
    Allow  = 0
    Cancel = 1
