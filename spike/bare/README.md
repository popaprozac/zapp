# Bare runtime spike

Working notes + artifacts for migrating Zapp's worker engine to
[Holepunch's Bare](https://github.com/holepunchto/bare). See the memory
entry `project_bare_runtime_spike.md` for the full strategic context;
this directory holds the experimental code.

## Phase 0 — App Store SPI risk

Cleared. `libjsc` references 3 SPI symbols (`JSContextGroupSetExecutionTimeLimit`,
`JSGlobalContextSetUnhandledRejectionCallback`, `JSStringCreateWithCharactersNoCopy`),
all replaceable. Holepunch's Keet ships on the iOS App Store using these
through Bare → libjs → libjsc, which is the strongest precedent.

## Phase 1 — vendor + first build

Built locally at `/tmp/bare-spike/build`:

| Artifact | Size |
|---|---|
| `bin/bare` (full executable, libjsc engine, with TLS+crypto) | 4.86 MB |
| `libbare.a` | 720 KB |
| `libbare.dylib` | 835 KB |
| `libjs.a` | 94 KB |

Comparison: txiki ships at 6.5 MB, JSC native at 445 KB. Bare-JSC
sits between them and gets system-framework JSC (with JIT) where txiki
uses QuickJS (no JIT).

Configure command:
```bash
cd vendor/bare # or wherever bare is checked out
bun install
cmake -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DBARE_ENGINE="github:holepunchto/libjsc#main" \
  -DBARE_PREBUILDS=OFF
cmake --build build -j4
```

**Caveat:** the standalone `bin/bare` CLI crashes on startup with libjsc
HEAD (and at least one prior commit). Doesn't block embedding — when
Zapp embeds, we link `libbare.a` and call `bare_setup()` ourselves,
skipping the CLI entirely.

## Phase 2 — bridge latency benchmark

`jsc-napi-dispatch-bench.c` measures the per-call overhead of libjs's
NAPI dispatch pattern on JSC: `JSStringCreateWithUTF8CString` →
`JSObjectGetProperty` → `JSObjectGetPrivate` → invoke C callback. This
is the trampoline shape Bare-libjsc would route every host call
through.

Build + run:
```bash
clang -O2 -framework JavaScriptCore -framework Foundation \
  spike/bare/jsc-napi-dispatch-bench.c -o /tmp/jsc-bench
/tmp/jsc-bench
```

**Result on M4 Max:** ~0.16 µs/call (160 ns).

Reference points:
- Zapp JSC worker→native (current, via Cocoa JSContext blocks): 2.1 µs
- Zapp txiki worker→native (via QuickJS JS_NewCFunction): 0.3 µs
- Electron worker→native: 73 µs

The libjs NAPI primitive is genuinely faster than expected — comparable
to txiki and dramatically faster than Zapp's current Cocoa-block path.
The earlier 5-6 µs estimate from research was pessimistic; the actual
trampoline cost is ~160 ns. Adding our payload marshalling (JSON
serialize args + parse response) lands the full `Services.invokeSync`
round trip in the same ballpark Zapp has today.

**Verdict:** green light to proceed with the full integration.

## Phase 3 / next

Real integration into Zapp:
1. ✅ Vendor Bare into `vendor/bare` as a git submodule.
2. ✅ Wire its cmake build into `cli/src/native.ts` as `ensureBareBuilt(target, engine)`.
3. ✅ Dispatcher refactor: `worker.zc` runtime switch over 6 engines.
4. ✅ Minimum-viable `bare.c` with `__zappBridge.log`, slot table, embedded asset loading, terminate plumbing.
5. ⚠️ End-to-end link blocked on zc directive handling.
6. ⏳ Implement `Services.invokeSync` + `bridge.workerCrash` as NAPI host functions.
7. ⏳ Port hello-world's supervisor + ticker workers to Bare.
8. ⏳ Decide replace-vs-coexist with JSC native + txiki.

## Open issue: zc + multi-engine link plumbing

Enabling `ZAPP_WORKER_ENGINE_BARE_JSC` alongside `ZAPP_WORKER_ENGINE_TXIKI`
in the same `zapp/build.zc` produces undefined-symbol errors at link
time even though `libbare.a` / `libjs.a` are emitted on disk and the
generated `.zapp/zapp_platform.zc` references them with the exact paths.

### Strategies tried (all fail in different ways)

| Shape | Outcome |
|---|---|
| Two `//> link:` directives — one per engine | Only first honored; bare symbols missing |
| One `//> link:` per absolute static-lib path | clang tries to **compile** `libbare.a` as source ("expected identifier or '('"); paths from `link:` flow into compile invocations |
| `//> lib:` directives for `-L` + one `//> link:` per `-l` | Multiple `link:` directives still don't accumulate; some libs missing |
| Single consolidated `//> link: -L...all... -l...all...`  (one big line) | Seems correct in `.zapp/zapp_platform.zc` (879 chars) but linker still misses both txiki QuickJS symbols and Bare uv symbols |

The Zen-C 0.4.x docs (tour 12.5 Build Directives) document `//> lib:`
for `-L`, `//> include:` for `-I`, and `//> link:` for `-l<name>` /
`path/to/lib.a`. zc v0.4.3 (installed) appears to either:
- Not implement `lib:` / `include:` directives yet (silently ignore)
- Or process `link:` directives in a way that mangles -L/-l ordering
  on multi-engine consolidation

### Working baseline before the spike

Single engine (txiki alone, the way the framework shipped before this
spike) emits one `//> link: -L<txiki dirs> -l<txiki libs>` and links
fine. Adding any Bare directives (in any documented shape) breaks the
link, including paths that aren't logically related to the original
working directives.

### Next-session investigation

1. **Read zc's directive parser** (probably `zc-source-tree/src/build_directives.{c,zc}`):
   - Does `link:` accumulate or replace?
   - Are `lib:` / `include:` parsed in v0.4.3?
   - Is there a fixed-size buffer that truncates long directives?
2. **Try `-Wl,-force_load,<abs path>`** in cflags as a workaround —
   force-load is unconditional and bypasses search-path resolution.
3. **Or use `@cfg(ZAPP_WORKER_ENGINE_BARE_JSC)` import paths** that
   pull in the static libs via zc's `import` mechanism rather than
   directives.
4. **File a zc issue** with a minimal repro (two `//> link:` lines
   in one file, second is dropped).

### Build / run instructions to reproduce

```bash
# uncomment the line in hello-world/zapp/build.zc:
# //> macos: define: ZAPP_WORKER_ENGINE_BARE_JSC
cd hello-world && bun run build
# expect Undefined symbols error for _bare_setup et al.
```

Bare itself builds cleanly:
```bash
cd vendor/bare && bun install
cmake -B build-macos-jsc \
  -DCMAKE_BUILD_TYPE=Release \
  -DBARE_ENGINE=github:holepunchto/libjsc#main \
  -DBARE_PREBUILDS=OFF
cmake --build build-macos-jsc --target bare_static -j4
ls -la build-macos-jsc/libbare.a   # ~700 KB
ls -la build-macos-jsc/_deps/github+holepunchto+libjsc-build/libjs.a
ls -la build-macos-jsc/_deps/github+libuv+libuv-build/libuv.a
ls -la build-macos-jsc/_deps/github+holepunchto+libutf-build/libutf.a
```
