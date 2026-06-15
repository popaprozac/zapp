# Native Language Eval — Scorecard

Baseline: Zen-C hello-world ~708 KB. Probe links the SAME prebuilt
`probe_cocoa.o`, so size deltas reflect the language's runtime/stdlib overhead.

## Phase 1 — interop + size probe (macOS)

| Lang | Stripped size | Opens window? | JSON parse | C-header consume | Platform branch | Cross-compile | Authoring friction (vs Zen-C inventory) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Zig  | 188008 B (ReleaseSmall+strip) | yes (640x480 'zapp-spike', exit 0) | `std.json.parseFromSlice(Value)` — ergonomic; `.object.get(k).?.integer/.string` tagged-union access, clean | `@cImport(@cInclude("probe.h"))` — clean, zero binding boilerplate; pass `title.ptr` for `[*:0]const u8` | `builtin.os.tag == .macos` comptime `if` (dead branch elided) | yes — `x86_64-windows-gnu -lc` → PE32+ x86-64 from macOS, 488448 B, no toolchain install | 0.16 IO redesign drift: `std.fs.cwd().readFileAlloc(a,path,max)` → `std.Io.Dir.cwd().readFileAlloc(io,path,a,.limited(max))` w/ a `std.Io.Threaded` provider; otherwise terser & safer than Zen-C (explicit casts `@intCast`, `dupeZ` for NUL-term, no manual frees via arena) |
| Nim  | 102408 B (ORC default GC, `-d:release --opt:size`+strip); `--mm:none` also builds → 102520 B (+112 B — GC code negligible vs std/json+stdlib) | yes (640x480 'zapp-spike', exit 0) | `std/json` `parseFile(path)` → `JsonNode`; `cfg["w"].getInt`, `cfg["title"].getStr` — ergonomic, indexing + typed getters; raises on missing key | `proc … {.importc, cdecl.}` + `{.passC: "-I …".}` / `{.passL: "…probe_cocoa.o -framework Cocoa -lobjc".}` pragmas — clean, no separate binding gen; `cstring` maps directly to `const char*` | `when defined(macosx)` compile-time branch (dead `else` elided; only cocoa path codegen'd) | via C backend, not tested — `nim c --cpu:amd64 --os:windows -d:mingw …` cross-compiles by emitting C + invoking a cross C compiler (mingw); feasible, needs the cross toolchain installed | Nim COMPILES TO C like Zen-C, so the interop model is near-identical: `importc`+`passC`/`passL` ≈ Zen-C's link/cfg directives, and `{.emit: "…".}` drops raw C ≈ Zen-C `raw` blocks. GC story: default ORC (cycle-aware ref-counting) "just works" and adds only ~112 B here; `--mm:none` builds for this one-shot probe but is unsafe for long-lived/allocating code (no reclamation) — a real Zapp orchestration layer would keep ORC. Friction is low: typed JSON getters + auto `cstring` bridging beat manual C marshalling; main surprise is the ~100 KB binary floor — smaller than Zig's 188 KB, but std/json + stdlib + ORC set a higher baseline than a no-runtime lang. nimcache lands in `~/.cache/nim/` (outside repo). |
| C3   | 145064 B (`-Oz`+strip; `-Oz` = "tiny code, no debug info") | yes (640x480 'zapp-spike', exit 0) | `std::encoding::json` `json::tparse((String)data)` → `Object*?` tagged union; `cfg.get_int("w")` → `int?`, `cfg.get_string("title")` → `String?` — real, ergonomic, type-coercing optionals. Verified driving values (tampered json → window showed 321x654 'json-works', not defaults). JSON numbers stored as int128/double internally; getters coerce | NO C-header import — C3 can't consume `probe.h`. Hand-declare `extern fn void spike_cocoa_open_window(int w, int h, ZString title)`; symbol = fn name, `ZString` is `inline char*` so it bridges to C `const char*` directly. Clean once you know it, but it's manual (no `@cImport`/`importc`-style auto-binding) | compile-time `$if env::DARWIN: … $else … $endif`. `env::DARWIN` is a real stdlib `const bool` (core/env.c3); dead branch elided at compile time | LLVM targets — PARTIAL test: `compile-only --target windows-x64` emitted a real amd64 COFF `.obj` from macOS (cross-codegen works). Full PE link not attempted (needs a Windows `probe_cocoa.o` twin + `fetch-sdk windows`). `--list-targets` shows windows-x64/aarch64, mingw-x64, linux-x64, etc. | Mid maturity. Language ergonomics are pleasant — `try x = …` optional-unwrap binding, typed JSON getters, comptime `$if` with stdlib `const bool` predicates all read cleanly and beat manual C marshalling. The PAIN is toolchain/docs immaturity vs Zen-C: (1) NO C-header consumption — every C symbol is a hand-written `extern fn`, and you must KNOW `ZString = inline char*` and that the link name is the bare fn name (no `@extern("…")` needed here, but undocumented in-tool). (2) The link incantation took the longest to find: extra object files go through `-z <arg>` (raw linker passthrough), frameworks are `-z -framework -z Cocoa` (each token separate), `-l objc` for libobjc — discovered by reading `c3c compile --help` + iterating; no in-repo manifest needed for a single-file compile. (3) stdlib is undocumented in-tool — had to grep `$(brew --prefix c3c)/lib/c3/std/**` to find `json::tparse`, `Object.get_int`, `file::load_temp`, `String.zstr_tcopy`, `env::DARWIN`. (4) Error messages are decent (LLVM-backed, clear on type mismatches). (5) Harmless `ld` warning: prebuilt `.o` is macOS 26.0, c3c defaults min to 11.0 (could pin via `--macos-min-version`). Net: ~20 min to first working link, almost all of it API/flag discovery, not fighting the compiler. Size sits BETWEEN Nim (102 KB) and Zig (188 KB) — no GC, no heavy runtime; the ~145 KB is mostly stdlib + panic/temp-allocator scaffolding. Younger ecosystem than the others; viable but you live in the source tree for API discovery. |
| Odin | 234008 B (`-o:size`+`strip`; `-o:size` = optimize for binary size) | yes (640x480 'zapp-spike', exit 0) | `core:encoding/json` `json.parse(data) -> (Value, Error)`; `Value` is a union; `Object` = `distinct map[string]Value`. Access via type-assert: `obj, ok := value.(json.Object)`, then `v, has := obj["w"]`, `f, fok := v.(json.Float)`. GOTCHA confirmed: `parse_integers=false` by default → JSON ints decode as `json.Float` (f64), so `i32(f)` cast needed (`json.Integer`/i64 only if you pass `parse_integers=true`). Ergonomic, tagged-union switch is clean. Verified driving values (tampered json → window showed 321x654 'json-works', not defaults) | NO C-header import — Odin can't consume `probe.h`. Hand-declare: `foreign import probe "../shared/probe_cocoa.o"` (path relative to the .odin SOURCE file) + `@(default_calling_convention="c") foreign probe { spike_cocoa_open_window :: proc(w,h: i32, title: cstring) --- }`. The `foreign import` of a bare `.o` pulls the object into the link automatically — clean, no separate binding gen. `cstring` maps directly to `const char*`; `strings.clone_to_cstring` NUL-terminates an Odin `string`. Manual (no `@cImport`-style auto-binding) but tidy once known | `when ODIN_OS == .Darwin { … } else { … }` — compile-time `when`; `ODIN_OS` is a built-in enum (`.Darwin`/`.Windows`/…); dead branch elided | `-target:` flag exists (windows_amd64, linux_*, wasm, etc. via `-target:"?"`), but on this dev-2026-06 build cross-LINKING is NOT supported: `-target:windows_amd64` → "Linking for cross compilation for this platform is not yet supported (windows amd64)". So: target codegen selectable, but no usable Windows binary from macOS out-of-box (weaker than Zig/C3 here) | STARTER API was stale — real friction was discovering live signatures, not language fighting. `os.read_entire_file` in dev-2026-06 is a proc GROUP requiring an EXPLICIT allocator (`context.allocator`) and returns `(data: []byte, err: os.Error)` — the `data, ok :=` bool form errors ("Assignment count mismatch"); `err` is a union compared to `nil`. Error messages are EXCELLENT: the compiler printed the exact overload signatures + a "Did you mean…" suggestion, so the fix was immediate. JSON is genuinely usable (no need to hardcode). Interop is the cleanest of the C-header-less langs: `foreign import "<relative .o>"` does the link wiring with zero flag-hunting (only `-framework Cocoa -lobjc` via `-extra-linker-flags`, all real first-try). vs Zen-C: Odin is a standalone backend (LLVM), not a C-emitter, so there's no `raw` C-block / `passC` escape hatch — every C symbol is a hand-written `foreign` decl (like C3, unlike Nim/Zen-C). Size sits HIGHEST of the four probes (~234 KB) — Odin's default `core:fmt`/runtime/`context` machinery + json set a heavier floor than Nim(102)/C3(145)/Zig(188). ~15 min total, almost all of it the read_entire_file signature + json union shape; flags & link worked first try. Mature, pleasant ergonomics; main caveats = binary-size floor and no cross-link today |
| C    | 50824 B (`-Os`+strip — THE FLOOR; smallest binary in the set) | yes (640x480 'zapp-spike', exit 0) | **none in stdlib** — C has no JSON parser. Values hardcoded (w=640, h=480, title="zapp-spike") — the absence IS the finding: any real use requires a third-party lib (cJSON, jansson, etc.) or hand-rolling. Exactly the ergonomic gap that caused Zapp to ship `json_safe.zc` | Native/trivial — `#include "probe.h"` directly; no binding tool, no extern hand-decl, no pragma. This IS the reference model everything else is measured against | `#ifdef __APPLE__` — the universally-understood preprocessor baseline; dead branch is NOT elided at the object level (just not linked). This is the `@cfg`/`_WIN32` mechanism Zapp already fights every day | Needs a per-target cross toolchain (e.g. osxcross for Linux→macOS, mingw64 for macOS→Windows); nothing is bundled — contrast with Zig's self-contained cross-compile | The ergonomic FLOOR: no Option/Result, no map/struct-impl, no safe strings, no GC, no generics, no error propagation sugar. Manual memory, manual NUL-termination, manual JSON, manual everything. Every feature the other candidates add is measured against the extra friction of NOT having it in C. Zero adoption risk; zero runtime; the only reason to stay here is binary size (50 KB vs Nim 102 KB / C3 145 KB / Zig 188 KB / Odin 234 KB) or absolute ABI control |

## Gate decision

All five cleared the basic bar (window opens; every binary 50–234 KB, far under
any multi-MB concern) — so this was a ranking gate, not a kill gate.

**Survivors advanced to Phase 2: Zig + Nim.** They are the two options genuinely
competitive with Zen-C, and they represent the two distinct migration
philosophies:
- **Zig** — best C interop (`@cImport` auto-reads our headers; matters for the
  52 header imports + 221 raw-block externs), and the standout
  cross-compilation (real Windows `.exe` from the Mac, 488 KB) that could end
  the "Windows must be built on the PC" split. Counter: Zig 0.16's pre-1.0 IO
  API churn broke the starter probe (an ongoing adoption tax).
- **Nim** — compiles to C exactly like Zen-C, `{.emit.}` is a drop-in for the
  221 `raw` blocks (most natural migration of the existing inline C), smallest
  non-C binary (102 KB), and the ONLY candidate whose probe ran with zero API
  drift (strongest maturity signal). Counter: GC (ORC; tunable, ~free in size).

**Not advanced (viable, but each lost a decisive axis):**
- **C3** (145 KB) — no C-header import (every symbol hand-declared); youngest
  ecosystem; good *web* docs (c3-lang.org) but weak in-tool/in-editor
  discoverability. Cross-compile partial (COFF obj only).
- **Odin** (234 KB) — heaviest binary; no cross-LINK from macOS in this build;
  standalone backend (no raw-C escape hatch). Excellent error messages + good
  web docs (odin-lang.org).
- **plain C** (50 KB) — the implicit baseline/yardstick, not separately sliced.

## Phase 2 — vertical slice (survivors)

### Zig slice

187896 B stripped (ReleaseSmall) — within ~100 B of the Phase 1 Zig probe
(188008 B), i.e. the router/struct/method/two-route logic adds essentially zero
size over the bare interop probe. Reimplements the `router_handle_window_action`
shape: parse a bridge message, dispatch on `m`, and for `window:create` build a
`WindowOptions` struct and call `.apply()`. Per-axis vs the Zen-C friction
inventory: **Routing/JSON ergonomics — strong.** `std.json.parseFromSlice(Value,
…)` over a multiline string literal (`\\…`) then `obj.get("m").?.string` /
`.integer` tagged-union access is clean and reads like the real router; the only
nit is no native string-switch, so dispatch is an `if (std.mem.eql(u8, m, …))`
chain (still tidy, exhaustive-by-intent with a default `else`). **Comptime
platform branch — best in the set, NO emit footgun.** `if (builtin.os.tag ==
.macos)` is a normal `if` on a comptime-known value; the dead branch is fully
elided (the macOS binary never references `spike_print_windows`). Unlike Zen-C
`@cfg`, nothing is emitted into "every TU" and there is no per-platform stub
obligation — the exact iOS-stub-parity tax we keep paying (`#ifdef __APPLE__`
true on iOS, every `darwin_*` needs an iOS twin) simply does not exist here; the
compiler just folds the constant. **Struct + method — clean.** `WindowOptions {
w, h, title }` with `fn apply(self) void` calling the C fn; routing
parse→build→`.apply()` is natural, methods are just namespaced fns, no
boilerplate. **Const-correctness — clean, ZERO cast wrangling.** `title` is a
`[:0]const u8` (immutable, sentinel-terminated via `a.dupeZ`), and `.ptr` yields
exactly `[*:0]const u8`, which `@cImport` mapped `const char*` to — it threads
JSON-const → struct field → C param with no discard-qualifier / cast fights of
the kind that bit us in Zen-C. **raw→wrapper — confirmed, no inline ObjC.** The
ObjC that sets `win.title` lives in `probe_cocoa.m` behind the plain C
`spike_cocoa_open_window`; the Zig `apply()` just forwards the const slice, so
the slice contains ZERO inline ObjC — proving the target architecture (ObjC in
`.m`, orchestration lang only marshals strings) vs Zen-C's `raw { … }` inline
blocks. **0.16 friction:** none new this slice — the Phase 1 IO-redesign drift
(`readFileAlloc` signature) didn't recur because the slice parses inline string
literals rather than reading a file; `@cImport`, `std.json.parseFromSlice`,
`builtin.os.tag`, and `dupeZ`→`.ptr` all worked first try, build + run + exit 0
on the first attempt.

### Nim slice

101816 B stripped (`-d:release --opt:size`) — ~592 B UNDER the Phase 1 Nim probe
(102408 B), i.e. the router/struct/method/cfg-branch/two-route logic adds nothing
measurable over the bare interop probe (std/json was already linked; the slice
just exercises more of it). Reimplements the `router_handle_window_action` shape:
`parseJson` a bridge message, dispatch on `m`, and for `window:create` build a
`WindowOptions` object and call `.apply()`. Per-axis vs the Zen-C friction
inventory: **Routing/JSON ergonomics — strong, arguably the cleanest in the set.**
`parseJson("""…""")` over a triple-quoted raw string literal then `node["m"].getStr`
/ `a["w"].getInt` typed getters read like the real router; and unlike Zig (no
native string-switch → `if eql(...)` chain) Nim has a real **string `case … of`**,
so dispatch is exhaustive-by-shape with a single `else` default — the most
router-like syntax of any candidate. (Caveat: `parseJson` + `[]` *raises* on
missing keys rather than returning an optional — fine for trusted bridge frames,
but a hostile/partial frame throws; the real router would want a `hasKey`/`getOrDefault`
guard.) **`when defined(macosx)` platform branch — best-tier, NO emit footgun.**
It's a compile-time predicate the codegen folds: only the cocoa path is emitted,
the macOS binary never references `spike_print_windows`. Unlike Zen-C `@cfg`,
nothing is emitted into "every TU" and there is no per-platform-stub obligation —
the exact iOS-stub-parity tax we keep paying (`#ifdef __APPLE__` is true on iOS too,
so every `darwin_*` needs an iOS twin) simply does not arise; `when` just drops the
dead branch. **Object + proc — clean, near-zero boilerplate.** `type WindowOptions
= object` with `proc apply(self: WindowOptions)` is a normal value type + a
free-standing proc dispatched by first-arg type (UFCS), so `opts.apply()` reads as
a method with no class/impl ceremony; routing parse→build-object→`apply` is
natural. **Const-correctness — clean, ZERO cast wrangling.** The parsed `title` is
an immutable Nim `string`; threading it through the object field and calling
`.cstring` views the backing buffer as a NUL-terminated `const char*` with no copy
and no discard-qualifier / cast fight — exactly the kind of const-through-the-struct
flow that bit us in Zen-C, here it just works. **raw→wrapper — confirmed, no inline
ObjC.** The ObjC that sets `win.title` lives in `probe_cocoa.m` behind the plain C
`spike_cocoa_open_window`; `apply()` only forwards the marshalled string, so the
slice contains ZERO inline ObjC — proving the target architecture (ObjC in `.m`,
orchestration lang marshals strings only). And the direct analogue to Zen-C's
`raw { … }` blocks, if inline C were ever genuinely needed, is Nim's `{.emit:
"…".}` pragma (noted, deliberately unused). **Compiles-to-C parallel — the
decisive edge over Zig here.** Nim emits C and links it exactly like Zen-C, so the
whole interop model is the closest migration: `importc`+`passC`/`passL` ≈ Zen-C's
link/cfg directives, `{.emit.}` is a drop-in for the 221 `raw` blocks, and the
existing inline C/ObjC could migrate almost mechanically. **Nim friction:** none new
this slice — `parseJson`, typed getters, the string `case`, `when defined`, and
`.cstring` bridging all worked first try; build + run + exit 0 on the first attempt
with zero API drift (the same maturity signal as Phase 1). Only standing caveats
carry over: the raise-on-missing-key JSON access (defensive guards needed for
untrusted frames) and the ORC GC (default, ~free in size, correct to keep for a
real long-lived orchestration layer).

## Recommendation
(filled at the end — covers adopt-X / stay-Zen-C / drop-to-C)
