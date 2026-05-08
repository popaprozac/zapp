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
1. Vendor Bare into `vendor/bare` as a git submodule.
2. Wire its cmake build into `cli/src/native.ts` as a third worker engine option.
3. Implement `Services.invokeSync` + `bridge.workerCrash` as a NAPI addon.
4. Port hello-world's supervisor + ticker workers to Bare.
5. Benchmark full bridge latency on the integrated system.
6. Decide replace-vs-coexist with JSC native + txiki.
