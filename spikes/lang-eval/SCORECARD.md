# Native Language Eval — Scorecard

Baseline: Zen-C hello-world ~708 KB. Probe links the SAME prebuilt
`probe_cocoa.o`, so size deltas reflect the language's runtime/stdlib overhead.

## Phase 1 — interop + size probe (macOS)

| Lang | Stripped size | Opens window? | JSON parse | C-header consume | Platform branch | Cross-compile | Authoring friction (vs Zen-C inventory) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Zig  | 188008 B (ReleaseSmall+strip) | yes (640x480 'zapp-spike', exit 0) | `std.json.parseFromSlice(Value)` — ergonomic; `.object.get(k).?.integer/.string` tagged-union access, clean | `@cImport(@cInclude("probe.h"))` — clean, zero binding boilerplate; pass `title.ptr` for `[*:0]const u8` | `builtin.os.tag == .macos` comptime `if` (dead branch elided) | yes — `x86_64-windows-gnu -lc` → PE32+ x86-64 from macOS, 488448 B, no toolchain install | 0.16 IO redesign drift: `std.fs.cwd().readFileAlloc(a,path,max)` → `std.Io.Dir.cwd().readFileAlloc(io,path,a,.limited(max))` w/ a `std.Io.Threaded` provider; otherwise terser & safer than Zen-C (explicit casts `@intCast`, `dupeZ` for NUL-term, no manual frees via arena) |
| Nim  |  |  |  |  |  |  |  |
| C3   |  |  |  |  |  |  |  |
| Odin |  |  |  |  |  |  |  |
| C    |  |  |  |  |  |  |  |

## Gate decision
(survivors + why — filled at the gate)

## Phase 2 — vertical slice (survivors)
(filled in Phase 2)

## Recommendation
(filled at the end — covers adopt-X / stay-Zen-C / drop-to-C)
