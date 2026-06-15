## Phase 2 vertical slice (Nim) — reimplements one real Zapp path
## (mirrors `router_handle_window_action`) to grade ergonomics on the patterns
## we actually use: bridge-JSON -> route on `m` -> window create, a platform-gated
## action, a struct+method, const-correctness threading, and the raw->.m-wrapper
## architecture (no inline ObjC in the orchestration lang).

import std/json

{.passC: "-I spikes/lang-eval/shared".}
{.passL: "spikes/lang-eval/shared/probe_cocoa.o -framework Cocoa -lobjc".}

# C-ABI surface (ObjC behind plain C). Nim compiles to C like Zen-C, so this
# `importc`+`passC`/`passL` trio is the near-exact analogue of Zen-C's link/cfg
# directives — no separate binding generator. `cstring` maps to `const char*`.
proc spike_cocoa_open_window(w, h: cint, title: cstring) {.importc, cdecl.}
proc spike_print_windows() {.importc, cdecl.}
proc spike_cocoa_beep() {.importc, cdecl.}

# (3) A struct + method — the WindowOptions-like value object.
type WindowOptions = object
  w, h: cint
  title: string   # (4) the immutable title from JSON lives here, unchanged.

# (5) raw->wrapper: the ObjC that sets `win.title` lives in probe_cocoa.m behind
# the plain C `spike_cocoa_open_window`. This proc just forwards the parsed
# title — ZERO inline ObjC in Nim. That is the target architecture (ObjC in .m,
# orchestration lang only marshals strings) vs Zen-C's `raw { ... }` blocks that
# inline ObjC into the .zc. If inline C were ever truly needed, Nim's
# `{.emit: "...".}` pragma is the drop-in `raw`-block analogue — but the whole
# point here is we don't need it.
# (4) Const-correctness: `self.title` is an immutable Nim `string`; `.cstring`
# views its backing buffer as a NUL-terminated `const char*` with no copy and no
# cast wrangling — clean, none of the discard-qualifier fights Zen-C hit.
proc apply(self: WindowOptions) =
  spike_cocoa_open_window(self.w, self.h, self.title.cstring)

# (1)+(3)+(4) window:create handler — pull `a.w`,`a.h`,`a.title`, build the
# struct, .apply(). Typed JSON getters (`getInt`/`getStr`) read like the router.
proc handleWindowCreate(a: JsonNode) =
  let opts = WindowOptions(
    w: a["w"].getInt.cint,
    h: a["h"].getInt.cint,
    title: a["title"].getStr,
  )
  opts.apply()

# (2) platform-gated action — COMPILE-TIME OS branch. `when defined(macosx)` is
# resolved at compile time, so the dead `else` is elided and only the cocoa path
# is codegen'd (the macOS binary never references `spike_print_windows`).
# Contrast Zen-C `@cfg`, which emits the guarded import/decl into EVERY
# translation unit and forces a per-platform stub (the iOS-stub-parity tax:
# `#ifdef __APPLE__` is true on iOS too, so every `darwin_*` needs an iOS twin) —
# here `when` just folds the constant, no emit footgun, no stub obligation.
proc handleDockBounce() =
  when defined(macosx):
    spike_cocoa_beep()
  else:
    spike_print_windows()

# The router — dispatch on the bridge message's `m` field. This is the slice's
# analogue of `router_handle_window_action`. Nim HAS a native string `case`, so
# dispatch is exhaustive-by-shape with an `else` default — tidier than the
# `if eql(...)` chains C-style langs fall back to.
proc route(msg: string) =
  let node = parseJson(msg)
  case node["m"].getStr
  of "window:create":
    handleWindowCreate(node["a"])
  of "dock:bounce":
    handleDockBounce()
  else:
    echo "[slice] unrouted message: ", node["m"].getStr

# (1) Bridge JSON -> route -> window create. parseJson over a string literal
# (not a file), exactly the bytes the bridge would hand us.
route("""{"t":4,"m":"window:create","a":{"w":700,"h":500,"title":"slice"}}""")

# (2) platform-gated action.
route("""{"t":4,"m":"dock:bounce"}""")
