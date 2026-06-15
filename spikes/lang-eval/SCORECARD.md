# Native Language Eval — Scorecard

Every probe links the SAME prebuilt `probe_cocoa.o`, so size deltas reflect the
language's runtime/stdlib overhead. The incumbent **Zen-C now has its own probe
row** (112 KB) — the true apples-to-apples baseline. (The ~708 KB figure quoted
elsewhere is the full Zen-C *hello-world app* — router, window manager, every
native feature — NOT comparable to these minimal probes; it measures the app, not
the language floor.)

## Phase 1 — interop + size probe (macOS)

| Lang | Stripped size | Opens window? | JSON parse | C-header consume | Platform branch | Cross-compile | Authoring friction (vs Zen-C inventory) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **Zen-C** (incumbent) | 112472 B (`-Oz --release`+strip) | yes (640x480 'zapp-spike', exit 0) | `std/json.zc` `JsonValue::parse(text)` → `Result<JsonValue*>`; `j.get_int("w")` → `Option<int>`, `j.get_string("title")` → `Option<char*>`, `.unwrap_or(default)` — typed getters, ergonomic, on par with the candidates. CAVEAT: stdlib `JsonValue::parse` carries the known **4 KB stack-buffer overflow** on long string tokens (fine for this tiny input; production Zapp ships the heap-allocating `json_safe.zc` replacement — the maturity ding that *forced* that file, the direct analogue of C's "no stdlib JSON" gap) | NATIVE — `import "probe.h" as spike;` consumes the C header directly (resolved via `-I`), then `spike::spike_cocoa_open_window(...)`. Best-tier interop alongside C's `#include` and Zig's `@cImport`; no hand-declared `extern` like C3/Odin | `@cfg(apple)` / `@cfg(windows)` — but **DUPLICATES THE WHOLE FN per platform** (had to write `open_window` twice). This IS the per-platform-stub tax the comptime-folding candidates (Zig `if builtin.os.tag`, Nim `when defined`) avoid by eliding a dead branch of ONE fn. zc also analyzes the non-targeted branch (spurious "unused param" warnings on the windows fn during a macOS build) | needs a per-target cross toolchain like plain C — no bundled self-contained cross-compile à la Zig; not exercised here | THE INCUMBENT — this row IS the friction inventory's baseline. Re-confirmed live: (1) compiles-to-C, so `raw { … }` is the native inline-C/ObjC escape hatch — the **221 existing raw blocks need ZERO migration** (they're already Zen-C); (2) toolchain just works — 0.7 s build, zero errors, zero API drift (it's the daily driver); (3) `raw{}` blocks are OPAQUE to zc's usage analysis → a param used only inside a raw block is wrongly flagged "unused" (`path` in `read_text`); (4) no stdlib file-read → dropped to a raw `fopen` block (candidates each had a 1-call stdlib read); (5) harmless `ld` `__common` alignment warning. Version `v0.4.4-217-g10cf66d-dirty` — itself a **pre-1.0 language** (the exact maturity concern that prompted this spike). Size 112 KB = **MID-PACK**: above C(51)/Nim(102), below C3(145)/Zig(188)/Odin(234); std/json + Vec/Map/Option/Result codegen sets the floor |
| Zig  | 188008 B (ReleaseSmall+strip) | yes (640x480 'zapp-spike', exit 0) | `std.json.parseFromSlice(Value)` — ergonomic; `.object.get(k).?.integer/.string` tagged-union access, clean | `@cImport(@cInclude("probe.h"))` — clean, zero binding boilerplate; pass `title.ptr` for `[*:0]const u8` | `builtin.os.tag == .macos` comptime `if` (dead branch elided) | yes — `x86_64-windows-gnu -lc` → PE32+ x86-64 from macOS, 488448 B, no toolchain install | 0.16 IO redesign drift: `std.fs.cwd().readFileAlloc(a,path,max)` → `std.Io.Dir.cwd().readFileAlloc(io,path,a,.limited(max))` w/ a `std.Io.Threaded` provider; otherwise terser & safer than Zen-C (explicit casts `@intCast`, `dupeZ` for NUL-term, no manual frees via arena) |
| Nim  | 102408 B (ORC default GC, `-d:release --opt:size`+strip); `--mm:none` also builds → 102520 B (+112 B — GC code negligible vs std/json+stdlib) | yes (640x480 'zapp-spike', exit 0) | `std/json` `parseFile(path)` → `JsonNode`; `cfg["w"].getInt`, `cfg["title"].getStr` — ergonomic, indexing + typed getters; raises on missing key | `proc … {.importc, cdecl.}` + `{.passC: "-I …".}` / `{.passL: "…probe_cocoa.o -framework Cocoa -lobjc".}` pragmas — clean, no separate binding gen; `cstring` maps directly to `const char*` | `when defined(macosx)` compile-time branch (dead `else` elided; only cocoa path codegen'd) | via C backend, not tested — `nim c --cpu:amd64 --os:windows -d:mingw …` cross-compiles by emitting C + invoking a cross C compiler (mingw); feasible, needs the cross toolchain installed | Nim COMPILES TO C like Zen-C, so the interop model is near-identical: `importc`+`passC`/`passL` ≈ Zen-C's link/cfg directives, and `{.emit: "…".}` drops raw C ≈ Zen-C `raw` blocks. GC story: default ORC (cycle-aware ref-counting) "just works" and adds only ~112 B here; `--mm:none` builds for this one-shot probe but is unsafe for long-lived/allocating code (no reclamation) — a real Zapp orchestration layer would keep ORC. Friction is low: typed JSON getters + auto `cstring` bridging beat manual C marshalling; main surprise is the ~100 KB binary floor — smaller than Zig's 188 KB, but std/json + stdlib + ORC set a higher baseline than a no-runtime lang. nimcache lands in `~/.cache/nim/` (outside repo). |
| C3   | 145064 B (`-Oz`+strip; `-Oz` = "tiny code, no debug info") | yes (640x480 'zapp-spike', exit 0) | `std::encoding::json` `json::tparse((String)data)` → `Object*?` tagged union; `cfg.get_int("w")` → `int?`, `cfg.get_string("title")` → `String?` — real, ergonomic, type-coercing optionals. Verified driving values (tampered json → window showed 321x654 'json-works', not defaults). JSON numbers stored as int128/double internally; getters coerce | NO C-header import — C3 can't consume `probe.h`. Hand-declare `extern fn void spike_cocoa_open_window(int w, int h, ZString title)`; symbol = fn name, `ZString` is `inline char*` so it bridges to C `const char*` directly. Clean once you know it, but it's manual (no `@cImport`/`importc`-style auto-binding) | compile-time `$if env::DARWIN: … $else … $endif`. `env::DARWIN` is a real stdlib `const bool` (core/env.c3); dead branch elided at compile time | LLVM targets — PARTIAL test: `compile-only --target windows-x64` emitted a real amd64 COFF `.obj` from macOS (cross-codegen works). Full PE link not attempted (needs a Windows `probe_cocoa.o` twin + `fetch-sdk windows`). `--list-targets` shows windows-x64/aarch64, mingw-x64, linux-x64, etc. | Mid maturity. Language ergonomics are pleasant — `try x = …` optional-unwrap binding, typed JSON getters, comptime `$if` with stdlib `const bool` predicates all read cleanly and beat manual C marshalling. The PAIN is toolchain/docs immaturity vs Zen-C: (1) NO C-header consumption — every C symbol is a hand-written `extern fn`, and you must KNOW `ZString = inline char*` and that the link name is the bare fn name (no `@extern("…")` needed here, but undocumented in-tool). (2) The link incantation took the longest to find: extra object files go through `-z <arg>` (raw linker passthrough), frameworks are `-z -framework -z Cocoa` (each token separate), `-l objc` for libobjc — discovered by reading `c3c compile --help` + iterating; no in-repo manifest needed for a single-file compile. (3) stdlib is undocumented in-tool — had to grep `$(brew --prefix c3c)/lib/c3/std/**` to find `json::tparse`, `Object.get_int`, `file::load_temp`, `String.zstr_tcopy`, `env::DARWIN`. (4) Error messages are decent (LLVM-backed, clear on type mismatches). (5) Harmless `ld` warning: prebuilt `.o` is macOS 26.0, c3c defaults min to 11.0 (could pin via `--macos-min-version`). Net: ~20 min to first working link, almost all of it API/flag discovery, not fighting the compiler. Size sits BETWEEN Nim (102 KB) and Zig (188 KB) — no GC, no heavy runtime; the ~145 KB is mostly stdlib + panic/temp-allocator scaffolding. Younger ecosystem than the others; viable but you live in the source tree for API discovery. |
| Odin | 234008 B (`-o:size`+`strip`; `-o:size` = optimize for binary size) | yes (640x480 'zapp-spike', exit 0) | `core:encoding/json` `json.parse(data) -> (Value, Error)`; `Value` is a union; `Object` = `distinct map[string]Value`. Access via type-assert: `obj, ok := value.(json.Object)`, then `v, has := obj["w"]`, `f, fok := v.(json.Float)`. GOTCHA confirmed: `parse_integers=false` by default → JSON ints decode as `json.Float` (f64), so `i32(f)` cast needed (`json.Integer`/i64 only if you pass `parse_integers=true`). Ergonomic, tagged-union switch is clean. Verified driving values (tampered json → window showed 321x654 'json-works', not defaults) | NO C-header import — Odin can't consume `probe.h`. Hand-declare: `foreign import probe "../shared/probe_cocoa.o"` (path relative to the .odin SOURCE file) + `@(default_calling_convention="c") foreign probe { spike_cocoa_open_window :: proc(w,h: i32, title: cstring) --- }`. The `foreign import` of a bare `.o` pulls the object into the link automatically — clean, no separate binding gen. `cstring` maps directly to `const char*`; `strings.clone_to_cstring` NUL-terminates an Odin `string`. Manual (no `@cImport`-style auto-binding) but tidy once known | `when ODIN_OS == .Darwin { … } else { … }` — compile-time `when`; `ODIN_OS` is a built-in enum (`.Darwin`/`.Windows`/…); dead branch elided | `-target:` flag exists (windows_amd64, linux_*, wasm, etc. via `-target:"?"`), but on this dev-2026-06 build cross-LINKING is NOT supported: `-target:windows_amd64` → "Linking for cross compilation for this platform is not yet supported (windows amd64)". So: target codegen selectable, but no usable Windows binary from macOS out-of-box (weaker than Zig/C3 here) | STARTER API was stale — real friction was discovering live signatures, not language fighting. `os.read_entire_file` in dev-2026-06 is a proc GROUP requiring an EXPLICIT allocator (`context.allocator`) and returns `(data: []byte, err: os.Error)` — the `data, ok :=` bool form errors ("Assignment count mismatch"); `err` is a union compared to `nil`. Error messages are EXCELLENT: the compiler printed the exact overload signatures + a "Did you mean…" suggestion, so the fix was immediate. JSON is genuinely usable (no need to hardcode). Interop is the cleanest of the C-header-less langs: `foreign import "<relative .o>"` does the link wiring with zero flag-hunting (only `-framework Cocoa -lobjc` via `-extra-linker-flags`, all real first-try). vs Zen-C: Odin is a standalone backend (LLVM), not a C-emitter, so there's no `raw` C-block / `passC` escape hatch — every C symbol is a hand-written `foreign` decl (like C3, unlike Nim/Zen-C). Size sits HIGHEST of the four probes (~234 KB) — Odin's default `core:fmt`/runtime/`context` machinery + json set a heavier floor than Nim(102)/C3(145)/Zig(188). ~15 min total, almost all of it the read_entire_file signature + json union shape; flags & link worked first try. Mature, pleasant ergonomics; main caveats = binary-size floor and no cross-link today |
| C    | 50824 B (`-Os`+strip — THE FLOOR; smallest binary in the set) | yes (640x480 'zapp-spike', exit 0) | **none in stdlib** — C has no JSON parser. Values hardcoded (w=640, h=480, title="zapp-spike") — the absence IS the finding: any real use requires a third-party lib (cJSON, jansson, etc.) or hand-rolling. Exactly the ergonomic gap that caused Zapp to ship `json_safe.zc` | Native/trivial — `#include "probe.h"` directly; no binding tool, no extern hand-decl, no pragma. This IS the reference model everything else is measured against | `#ifdef __APPLE__` — the universally-understood preprocessor baseline; dead branch is NOT elided at the object level (just not linked). This is the `@cfg`/`_WIN32` mechanism Zapp already fights every day | Needs a per-target cross toolchain (e.g. osxcross for Linux→macOS, mingw64 for macOS→Windows); nothing is bundled — contrast with Zig's self-contained cross-compile | The ergonomic FLOOR: no Option/Result, no map/struct-impl, no safe strings, no GC, no generics, no error propagation sugar. Manual memory, manual NUL-termination, manual JSON, manual everything. Every feature the other candidates add is measured against the extra friction of NOT having it in C. Zero adoption risk; zero runtime; the only reason to stay here is binary size (50 KB vs Nim 102 KB / C3 145 KB / Zig 188 KB / Odin 234 KB) or absolute ABI control |
| Swift (added 2026-06-15) | 56424 B (`-Osize`+strip, **DYNAMIC** — Apple runtime is OS-resident) | yes (640x480 'zapp-spike', exit 0) | Foundation `JSONDecoder().decode(Config.self, from: data)` over a `Codable` struct — type-safe, throwing/**catchable**, the most robust JSON in the set: explicit optionals, a missing *required* key throws (vs Zig's `.?` trap / Nim's `[]` raise) | **BEST-IN-SET.** Native ObjC/C interop: `-import-objc-header probe.h` exposes `spike_cocoa_open_window` directly, and a Swift `String` **auto-bridges** to `const char*` for the call — no NUL-term, no cast, no shim. Swift wouldn't even need the plain-C wrapper; it can call ObjC/AppKit directly | `#if os(macOS)` compile-time, dead branch elided — best-tier, no emit footgun, no stub twin (like Zig/Nim). Also a native string `switch` (like Nim) | N/A from macOS. **THE SIZE CAVEAT:** `-static-stdlib` is **disallowed on Apple** (Swift 6.3: "no longer supported for Apple platforms") — the 56 KB is **OS-SUBSIDIZED** (runtime in the OS, can't be statically linked). Off-Apple (Windows/Linux) you **ship the Swift runtime** (multi-MB) and can't slim it the way the others static-link. Swift's tiny Apple number does NOT transfer cross-platform | LOWEST authoring friction — Codable, bridging header, String bridging, `#if os`, string `switch` all worked **first try, zero API drift** (probe + slice). (SourceKit flags "cannot find spike_… in scope" — editor false positive, doesn't see `-import-objc-header`; real build clean.) MATURITY/ADOPTION = **HIGHEST of the field** (Apple's own language, massive community) — the opposite pole from Zen-C. The cost is *strategic, not ergonomic*: cross-platform (Windows) maturity + runtime-shipping is the risk for a framework whose pitch includes Windows |

## Gate decision

All five candidates cleared the basic bar (window opens; every binary 50–234 KB,
far under any multi-MB concern) — so this was a ranking gate, not a kill gate.
The incumbent **Zen-C measured 112 KB** under the identical contract, landing
mid-pack — so size is not a reason to leave it *or* a reason it uniquely wins
(Nim's 102 KB floor is actually smaller).

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

**Reopened 2026-06-15 — maturity + adoption elevated to the PRIMARY lens (user
direction).** The first gate ranked on six co-equal axes; the user reframed the
decision around *stability + how many people use it*, which (a) excludes **Rust**
and **Go** — both viable but their markets are saturated (Tauri owns Rust, Wails
owns Go), so no differentiation for Zapp — and (b) added **Swift**. It also
*re-rates* the survivors: **Zig's pre-1.0 risk is materially lower than first
framed** because **Vercel Labs' `zero-native` already ships a Zig desktop shell in
the same problem domain** — a well-resourced precedent. So the live migration
field on the maturity lens is **Zig (Vercel-validated, fast-growing), Swift
(Apple's own — highest adoption, best interop, cross-platform tax), and Nim
(small-but-stable, approachable, cleanest migration)**. Swift advanced to a Phase
2 slice alongside Zig + Nim.

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

### Swift slice (added 2026-06-15)

76968 B stripped (`-Osize`, **dynamic** — runtime OS-resident), vs the 56424 B
Phase 1 probe (+20.5 KB for the second Codable type + router `switch`; still
tiny, still OS-subsidized). Reimplements the `router_handle_window_action` shape:
decode a bridge frame, dispatch on `m`, and for `window:create` build a
`WindowOptions` value type and call `.apply()`. Per-axis vs the Zen-C friction
inventory: **Routing/JSON ergonomics — top-tier and the most *robust* of the
set.** `JSONDecoder().decode(BridgeMsg.self, …)` over `Codable` structs is fully
typed — no dictionary access at all — and the optional `a: WindowArgs?` field
models "present only for window:create" exactly (nil when absent, a *missing
required* key throws a catchable `DecodingError`). Dispatch is a native Swift
string `switch` with a `default` — exhaustive-by-shape like Nim, unlike Zig's
`eql` chain. The only nit vs the raw-Value parsers: Codable wants a declared
shape up front (more ceremony than `obj.get("m")`), which is *more* safety, not
less. **Platform branch — best-tier, no emit footgun.** `#if os(macOS)` is a
compile-time fold; the dead branch is elided (`spike_print_windows` never linked
on macOS). Like Zig/Nim and unlike Zen-C `@cfg`, there is NO per-platform-stub
duplication and nothing emitted into "every TU" — the iOS-stub-parity tax simply
does not exist. **Struct + method — clean, zero boilerplate.** `struct
WindowOptions { … func apply() }` is a value type with a method; `WindowOptions(…)
.apply()` reads exactly like the real builder. **Const-correctness — BEST in the
set, literally zero marshalling.** `title` is an immutable Swift `String`;
calling `spike_cocoa_open_window(w, h, title)` *auto-bridges* the String to a
NUL-terminated `const char*` for the call — no `dupeZ` (Zig), no `.cstring` view
(Nim), no `strdup`/cast (C/Zen-C). The interop layer is invisible. **raw→wrapper —
confirmed, and Swift wouldn't even need the wrapper.** The ObjC lives in
`probe_cocoa.m` behind plain C; `apply()` just forwards — ZERO inline ObjC. But
note the asymmetry: Swift has *native* ObjC interop, so in a real port the `.m`
files could be called directly (or rewritten in Swift) with no C-ABI shim at all
— strictly more capable than every other candidate including Zen-C's `raw{}`.
**Maturity/adoption — the highest in the field** (Apple's own language; the
opposite pole from Zen-C's near-solo bus factor). **Swift friction:** none new
this slice — Codable, the string `switch`, `#if os`, and String→`const char*`
bridging all worked first try, zero API drift. **The standing caveat is
strategic, not ergonomic:** the size is OS-subsidized (no static-stdlib on
Apple), and the cross-platform story — shipping the Swift runtime on Windows/Linux
+ the relative immaturity of Swift-on-Windows — is the real risk for a framework
whose pitch includes Windows. Swift is the **Apple-first champion with a
cross-platform tax**.

## Recommendation

### Binary-size comparison (the criterion that turned out not to decide it)

| Lang   | Stripped probe | Δ over C floor | Runtime/stdlib tax |
| ---    | ---            | ---            | ---                |
| Swift  | 56,424 B*      | +5,600 B*      | *OS-resident runtime — NOT shipped on Apple (see note) |
| C      | 50,824 B       | —              | none (the floor)   |
| Nim    | 102,408 B      | +51,584 B      | std/json + stdlib + ORC GC |
| **Zen-C** (incumbent) | **112,472 B** | +61,648 B | std/json + Vec/Map/Option/Result codegen |
| C3     | 145,064 B      | +94,240 B      | stdlib + panic/temp-allocator |
| Zig    | 188,008 B      | +137,184 B     | stdlib + comptime scaffolding |
| Odin   | 234,008 B      | +183,184 B     | core:fmt/runtime/context + json |
| Zig (Windows cross) | 488,448 B | n/a (PE32+) | self-contained cross-compile, from the Mac |

\* **Swift's 56 KB is misleading** — it's the dynamic-linked Apple number, where
the Swift runtime lives in the OS and isn't counted (and `-static-stdlib` is
*disallowed* on Apple in Swift 6.3). Off-Apple (Windows/Linux) you ship the
runtime — multi-MB — so Swift is effectively the *largest* shipped footprint on
the platforms where size would matter, not the smallest. On Apple it's free; on
Windows it's a tax.

The spike's headline finding **inverts the question the user led with.** "If they
produce the same tiny binaries" was the gate — and they all do, *including the
incumbent*: the Zen-C probe measured **112 KB** under the identical contract,
landing mid-pack. (The ~708 KB Zen-C hello-world quoted elsewhere is a *whole
app* — router, window manager, every native feature — not the language floor;
the apples-to-apples baseline is this 112 KB probe.) Two honest consequences:
**(1) size eliminates no candidate** — even the heaviest floor (Odin, +183 KB
over C) is noise against a real app bundle + WKWebView; and **(2) Zen-C is not
uniquely small** — Nim's 102 KB floor actually undercuts it, and C is half its
size. The decision therefore rests entirely on the other axes: interop,
platform-conditional ergonomics, general ergonomics, cross-compilation, maturity,
and migration cost.

### Outcome A — adopt a new language

Under the **maturity + adoption lens** (the user's primary criterion), the field
is **Zig, Swift, or Nim** — Rust and Go are out (viable but their markets are
saturated: Tauri owns Rust, Wails owns Go, so Zapp gains no differentiation), and
C3/Odin lost a decisive axis (see Gate decision; both have solid *web* docs
[c3-lang.org, odin-lang.org] — "weak in-tool discoverability," not "no docs").

- **Zig** — pre-1.0, BUT its adoption risk is **materially lower than the spike
  first framed**: Vercel Labs' `zero-native` ships a Zig desktop shell in this
  exact domain, a well-resourced precedent. Strengths: best C interop
  (`@cImport` auto-reads our 52 headers), best platform branch (comptime fold, no
  iOS-stub-parity tax), and the standout — self-contained cross-compilation (a
  real Windows PE32+ from the Mac) that could end the "Windows builds on the PC"
  split. Cost: 0.16's IO redesign broke the starter probe mid-spike (the churn is
  real even if backed); no raw-C escape hatch, so the 221 `raw {}` ObjC blocks
  move into `.m` files.

- **Swift** — the **highest-adoption candidate** (Apple's own language) and the
  one with a *qualitatively different* structural payoff: it doesn't just *call*
  ObjC behind a C ABI like every other candidate — it can **delete the ObjC layer
  on Apple entirely**. On macOS + iOS you'd write Swift directly against
  AppKit/UIKit/WebKit, collapsing today's Zen-C→C-ABI→ObjC `.m` (≈8k lines) into
  one Swift codebase, and the JSON/interop ergonomics were the best in the spike
  (Codable, String auto-bridge). The cost is **strategic, concentrated on the
  non-Apple side**: the tiny size is OS-subsidized (no static-stdlib on Apple; you
  ship a multi-MB runtime on Windows/Linux), and Swift-on-Windows is the least
  battle-tested toolchain of the three — a direct tension with the Windows-parity
  mandate. Swift is the **Apple-first champion that bets the cross-platform core
  on Swift-on-Windows**.

- **Nim** — the *cleanest migration shape* and best small-but-stable fit: compiles
  to C exactly like Zen-C, so `importc`+`passC`/`passL` ≈ Zen-C's link/cfg
  directives and `{.emit.}` is a near-mechanical drop-in for the 221 `raw` blocks
  (the ObjC `.m` layer stays as-is, called the same way). Smallest non-C binary
  (102 KB), most router-like syntax (real string `case … of`), and the **only
  candidate with zero API drift across probe + slice**. Approachable. Costs: an
  ORC GC (tunable, ~free in size) and `parseJson` raises on missing keys
  (defensive guards for untrusted frames). The adoption counter: a *small*
  community — stable, but niche.

### Outcome B — stay on Zen-C

The friction inventory is real and was documented honestly — and the Zen-C probe
*re-demonstrated* part of it live: the `@cfg` per-platform branch forced writing
`open_window` **twice** (the very stub-duplication tax Zig/Nim fold into one
comptime-elided fn), and `raw{}` blocks are opaque to zc's usage analysis
(spurious "unused param" warnings). Add the standing items: const/cast wrangling,
the local `compat.h`/`--objective-c` compiler patches, the std/json 4 KB stack
overflow we replaced with `json_safe.zc`, dispatch-buffer truncation, `{`
f-string escaping, and the plain fact that zc is itself a **pre-1.0 language**
(`v0.4.4`). But four facts weigh the other way — and the probe strengthened two:

1. **The whole native layer is already written in it** — ~7,500 lines across 43
   `.zc` files, 221 raw blocks, 179 `@cfg` gates, load-bearing std/json+map+result.
   A rewrite is enormous and risky against a layer that *works and ships today*.
2. **Interop + the raw-block escape hatch are best-tier and migration-free.** The
   probe confirmed `import "probe.h"` consumes a C header *natively* (no
   hand-declared externs), and because Zen-C compiles to C, the 221 `raw {}`
   blocks are already in the target form — a switch to anything but Nim would
   have to relocate all of them.
3. **The friction is now known and worked-around**, not open: `json_safe.zc` heap
   parser, the compat.h patch, the #281 iOS-symbol-parity lint, the build-success
   gate. These were one-time taxes already paid.
4. **No candidate is decisively better enough to justify the rewrite.** Zig wins
   interop + cross-compile but adds pre-1.0 churn; Nim wins migration-shape +
   undercuts Zen-C's size by ~10 KB but adds a GC. Neither is a step-change —
   they're lateral moves with different trade-offs. *The pains we know beat the
   pains we don't.*

### Outcome C — drop to plain C

C is the floor (50 KB), zero adoption risk, zero runtime, and the reference
interop model (native `#include`, no binding tool). But it **re-introduces every
ergonomic pain Zen-C was adopted to eliminate**: no stdlib JSON (the exact gap
that forced `json_safe.zc` — we'd own a JSON lib again), no Option/Result, no
map/struct-impl, no safe strings, no generics, no error-propagation sugar,
manual memory and NUL-termination everywhere. The only rational driver is
absolute ABI control, or a blanket distrust of *all* young languages — and if
young-language risk is the real fear, note that C is the one fully de-risked
option *and that Zen-C itself is the young language in question*. The ergonomic
regression is severe; this is the worst fit for a layer that's mostly
JSON-routing and string-marshalling.

### If we had to ship the decision today

**Two readings, depending on which lens is primary.**

*On the original six-axis rubric:* **stay on Zen-C** — binary size is a
non-differentiator, and no candidate beats a working ~7,500-line layer by enough
to justify the rewrite. Do not drop to C (it un-solves what Zen-C solved).

*On the maturity + adoption lens (the user's elevated criterion):* the answer
shifts, because **on that axis Zen-C ranks LAST** — it is the least-adopted of
every option here (a pre-1.0 language we carry local patches for, with a
near-solo bus factor). Once "stable + widely used" is the priority, the "stay"
case rests almost entirely on *migration cost/inertia*, not on Zen-C being
better. That makes the decision genuinely live, and it comes down to three
contenders with sharply different bets:

- **Swift** — the boldest: highest adoption, and the only option that **deletes
  the ObjC layer on Apple** (write Swift directly against AppKit/UIKit, ≈8k lines
  of `.m` collapse in). Best ergonomics + interop. The bet is cross-platform:
  Swift-on-Windows is the least-proven toolchain and you ship a runtime there.
  Pick this if Zapp is willing to be **Apple-first with Windows as the harder
  half**.
- **Zig** — the cross-platform pragmatist: self-contained cross-compile could
  *unify* the build (Windows from the Mac), best C interop, and Vercel's
  zero-native de-risks the "is Zig ready?" question. The bet is pre-1.0 churn.
  Pick this if **one toolchain building every target** is the priority.
- **Nim** — the low-risk evolution: the *cleanest migration* (compiles-to-C, the
  `.m` layer and `raw`-block model survive almost unchanged), stable, approachable,
  zero API drift. The bet is a *small community* + a GC. Pick this if the goal is
  **off-ramp Zen-C's compiler-maintenance burden with the least disruption**.

The honest one-liner: *if size were the question, stay; since maturity + adoption
is the question, Zen-C is the weakest option on its own terms — so the real
choice is Swift (Apple-first, boldest), Zig (one-toolchain cross-platform), or
Nim (lowest-risk migration), and it turns on how much Zapp will bet on
Swift-on-Windows vs. how much it values collapsing the ObjC layer.*
