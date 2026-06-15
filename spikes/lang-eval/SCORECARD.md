# Native Language Eval — Scorecard

Baseline: Zen-C hello-world ~708 KB. Probe links the SAME prebuilt
`probe_cocoa.o`, so size deltas reflect the language's runtime/stdlib overhead.

## Phase 1 — interop + size probe (macOS)

| Lang | Stripped size | Opens window? | JSON parse | C-header consume | Platform branch | Cross-compile | Authoring friction (vs Zen-C inventory) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Zig  | 188008 B (ReleaseSmall+strip) | yes (640x480 'zapp-spike', exit 0) | `std.json.parseFromSlice(Value)` — ergonomic; `.object.get(k).?.integer/.string` tagged-union access, clean | `@cImport(@cInclude("probe.h"))` — clean, zero binding boilerplate; pass `title.ptr` for `[*:0]const u8` | `builtin.os.tag == .macos` comptime `if` (dead branch elided) | yes — `x86_64-windows-gnu -lc` → PE32+ x86-64 from macOS, 488448 B, no toolchain install | 0.16 IO redesign drift: `std.fs.cwd().readFileAlloc(a,path,max)` → `std.Io.Dir.cwd().readFileAlloc(io,path,a,.limited(max))` w/ a `std.Io.Threaded` provider; otherwise terser & safer than Zen-C (explicit casts `@intCast`, `dupeZ` for NUL-term, no manual frees via arena) |
| Nim  | 102408 B (ORC default GC, `-d:release --opt:size`+strip); `--mm:none` also builds → 102520 B (+112 B — GC code negligible vs std/json+stdlib) | yes (640x480 'zapp-spike', exit 0) | `std/json` `parseFile(path)` → `JsonNode`; `cfg["w"].getInt`, `cfg["title"].getStr` — ergonomic, indexing + typed getters; raises on missing key | `proc … {.importc, cdecl.}` + `{.passC: "-I …".}` / `{.passL: "…probe_cocoa.o -framework Cocoa -lobjc".}` pragmas — clean, no separate binding gen; `cstring` maps directly to `const char*` | `when defined(macosx)` compile-time branch (dead `else` elided; only cocoa path codegen'd) | via C backend, not tested — `nim c --cpu:amd64 --os:windows -d:mingw …` cross-compiles by emitting C + invoking a cross C compiler (mingw); feasible, needs the cross toolchain installed | Nim COMPILES TO C like Zen-C, so the interop model is near-identical: `importc`+`passC`/`passL` ≈ Zen-C's link/cfg directives, and `{.emit: "…".}` drops raw C ≈ Zen-C `raw` blocks. GC story: default ORC (cycle-aware ref-counting) "just works" and adds only ~112 B here; `--mm:none` builds for this one-shot probe but is unsafe for long-lived/allocating code (no reclamation) — a real Zapp orchestration layer would keep ORC. Friction is low: typed JSON getters + auto `cstring` bridging beat manual C marshalling; main surprise is the ~100 KB binary floor — smaller than Zig's 188 KB, but std/json + stdlib + ORC set a higher baseline than a no-runtime lang. nimcache lands in `~/.cache/nim/` (outside repo). |
| C3   |  |  |  |  |  |  |  |
| Odin |  |  |  |  |  |  |  |
| C    |  |  |  |  |  |  |  |

## Gate decision
(survivors + why — filled at the gate)

## Phase 2 — vertical slice (survivors)
(filled in Phase 2)

## Recommendation
(filled at the end — covers adopt-X / stay-Zen-C / drop-to-C)
