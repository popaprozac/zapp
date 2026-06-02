# Zapp Benchmarks

Head-to-head comparison of Zapp against the four other major desktop webview
frameworks on macOS:

- **Zapp** — first-party `zjs` engine (default, cross-platform, ~4.5 MB) with
  five additional `bare-*` engines available as opt-ins. The `host-bridge`
  bench under `apps/zapp-host-bridge/` compares per-call cost across engines
  side by side.
- **Tauri v2** (Rust + system webview)
- **Wails v3** (Go + system webview)
- **Electron** (Node + Chromium)
- **Electrobun** (Bun + system webview, self-extracting)

Every app in `apps/` is the same minimal hello-world: one 400×300 window, one
"Hello from *framework*" label, one "Ping" button, one native handler that
returns a timestamp. No workers, no dialogs, no menus, no assets. That's the
only way the comparison stays honest — we're measuring framework overhead,
not app features.

## Quick take

Latest numbers live in `RESULTS.md`. The shape you should expect:

- **Binary weight**: Zapp JSC ships a ~450 KB main executable. Tauri and
  Wails land around 8 MB. Electrobun ships ~17 MB as a compressed archive
  that self-extracts on first launch. Electron ships ~170 MB of Electron
  Framework binary in a ~260 MB bundle.
- **Startup**: All six frameworks are within ~20 ms of each other. macOS
  launch overhead dominates. Framework-internal init cost is small compared
  to kernel fork + dyld + window create.
- **Idle memory**: Zapp sits around 25-26 MB, Tauri/Wails 26-30 MB, Electron
  and Electrobun 80-100 MB because each runs multiple processes (Electron
  helpers / Electrobun launcher + bun child).

## Running it yourself

### Prerequisites

- macOS 14+ on Apple Silicon (the scripts assume arm64; x86 has not been
  verified)
- **Bun** 1.3+ — used as the package manager and task runner everywhere
- **Zen-C** (`zc`) on `$PATH` — for Zapp builds
- **cmake** — required when building any `bare-*` engine for Zapp (first build only)
- **Rust toolchain** (`rustup`) — for Tauri
- **Go 1.25+** and **wails3** CLI — for Wails
  (`go install github.com/wailsapp/wails/v3/cmd/wails3@latest`)
- **Xcode Command Line Tools** — provides `codesign`, `iconutil`,
  `footprint`, `PlistBuddy`

None of the benchmark apps require code signing — everything is measured
against adhoc-signed builds, which matches what a developer gets from
`cargo build` / `go build` / `npm run package` out of the box.

### One-shot build and measure

```bash
./scripts/build-all.sh cold   # wipe per-framework build outputs, then build
./scripts/build-all.sh hot    # incremental / cached rebuild (default if omitted)
./scripts/measure-all.sh      # run bench.sh per app, append to RESULTS.md
```

Running `cold` and then `hot` populates both columns in the RESULTS.md
table. `measure-all.sh` reads `.build-times.json` — written by
`build-all.sh` — and joins the build times onto the startup/idle rows.

Skip specific apps if a toolchain is missing:

```bash
SKIP_WAILS=1 SKIP_ELECTRON=1 ./scripts/build-all.sh cold
```

### Recommended full-run sequence

This is the order that produces honest, reproducible numbers with all
caveats respected:

```bash
# 1. clean baseline — every framework built from scratch in release mode
rm benchmarks/.build-times.json
./scripts/build-all.sh cold

# 2. snapshot size / startup / idle with cold build times folded in
./scripts/measure-all.sh

# 3. hot build times, then re-measure so hot numbers land in the table
./scripts/build-all.sh hot
./scripts/measure-all.sh

# 4. IPC bench — per app, paste bridge-bench.js into devtools console
#    (see the bridge benchmark section below)

# 5. Wails IPC only: rebuild with devtools first, then run the bench,
#    then rebuild back to production for any follow-up size/startup runs
./scripts/build-wails-devtools.sh
# ... launch Wails app, open devtools (auto), paste bridge-bench.js ...
./scripts/build-all.sh hot    # optional: restore production Wails
```

Why step 5 is separate: Wails' production build (`-tags production`)
stubs `openDevTools()` to an empty function, so devtools are
*unreachable* in a packaged Wails release. The IPC benchmark needs
devtools. `build-wails-devtools.sh` does a DEV=true rebuild that
drops the production tag — the only way to get devtools in a
packaged Wails build — with the tradeoff that DEV builds also
disable Go inlining. So Wails gets measured twice: once in
production mode for size/startup/idle (fair baseline), and once in
DEV mode for the IPC bench (the only build with accessible
devtools). Both numbers go in RESULTS.md with the mode annotated.

### Cold vs hot build timing

| Mode | What it measures | What it wipes first |
|---|---|---|
| **cold** | First build after checkout, with deps already resolved | project-local build outputs only |
| **hot** | Incremental / cached rebuild when nothing changed | nothing |

"Cold" deliberately does **not** wipe dep caches (`node_modules`,
`~/.cargo`, Go's build cache). We're measuring *compile time*, not
network speed — and the "first time a developer ever touches this
framework" metric is dominated by dependency fetching, which is
boring and noisy. A fair cold build is: "I already have the deps,
now how long does the compiler take?"

Per-framework wipe list (inside the project directory only):

| Framework | Cold wipe |
|---|---|
| zapp-host-bridge | `.zapp/` `bin/` `dist/` `release/` |
| tauri | `src-tauri/target/` `dist/` |
| wails | `bin/` `frontend/dist/` `frontend/bindings/` |
| electron | `out/` |
| electrobun | `build/` `artifacts/` |

Caveats that show up in the numbers:

- **Tauri cold is brutal.** A clean `cargo build --release` of Tauri
  v2 compiles hundreds of Rust crates (`wry`, `tao`, half of serde,
  all of Tauri's transitive deps). Expect 2-4 minutes on Apple
  Silicon. Hot rebuild is well under a second because Cargo caches
  everything.
- **Zapp cold ≈ hot.** The Zen-C compiler doesn't do incremental
  builds yet; every `bun run package` recompiles the full tree.
  Cold and hot timings should be within noise of each other.
- **Electron cold ≈ hot.** electron-forge rebuilds the `out/` bundle
  from scratch on every run. The wipe is really a no-op for
  electron's wall-clock time — but we still wipe for consistency.
- **Wails hot is fast.** Go's incremental compilation is excellent,
  so a no-change rebuild is dominated by Vite frontend bundling.

### Measuring a single framework

```bash
./bench.sh <path-to-app-or-parent-dir> <label> [runs]
```

Examples:

```bash
./bench.sh apps/zapp-jsc/release zapp-jsc
./bench.sh apps/tauri/src-tauri/target/release/bundle/macos tauri 25
```

Output is a single JSON line with `binary_bytes`, `bundle_bytes`,
`icon_bytes`, `startup_ms`, `startup_us`, `idle_mb`, and `binary_note`.

### Bridge round-trip benchmark

> **Wails caveat**: the production Wails build (what `build-all.sh`
> produces) stubs `openDevTools()` to an empty function via a
> compile-time build tag, so devtools are unreachable and
> `bridge-bench.js` can't run against it. Before the Wails IPC
> bench, run `./scripts/build-wails-devtools.sh` to rebuild
> `bin/wails.app` with `DEV=true`. This is a temporary build just
> for the IPC measurement — Wails size / startup / idle numbers
> come from the production build. See the
> devtools-in-release-builds subsection below for the full story.

`bridge-bench.js` times thousands of `ping` calls using **batched
timing** and reports min / median / mean / max / stdev of per-call
latency across batches. Every app exposes a single standardized hook
so the script has nothing framework-specific to detect:

```js
window.__bench.ping() -> Promise<{ pong: number }>
```

Under the hood that hook calls each framework's idiomatic IPC — a
`Services.invoke` for Zapp, `invoke()` for Tauri, a generated binding
call for Wails, `ipcRenderer.invoke` for Electron, `rpc.request.ping`
for Electrobun — but the bench script only cares that there's a
promise-returning `ping` on `window.__bench`.

#### Why batched timing

`performance.now()` is clamped to coarse granularity in release
webviews as a Spectre mitigation: WebKit rounds to **1 ms**, Chromium
to **0.1 ms**. An individual IPC call that takes ~50 µs just returns
0 or 1000 µs in Zapp/Tauri/Wails/Electrobun, so per-call timings are
meaningless in a packaged build.

The script works around this by timing *batches* of 200 sequential
calls in a single `performance.now()` pair. Each batch takes tens of
milliseconds — safely above the clamp — so the per-call average
derived from it is genuinely accurate. Running 30 batches gives 30
independent samples; min / median / mean / max / stdev across those
batches report the honest distribution of round-trip latency.

What we lose: per-call percentiles (p95/p99) at microsecond
resolution. What we keep: accurate mean throughput and a real sense
of variance between batches.

#### Running it

1. Build the app in release mode (`./scripts/build-all.sh` or the
   per-framework build command listed below).
2. Launch the `.app` bundle — by double-clicking in Finder or running
   `open -a path/to/<framework>.app`.
3. Open the webview's devtools:
   - **Zapp, Tauri, Wails, Electron**: right-click inside the window
     and pick "Inspect Element". Keyboard shortcut is usually
     Cmd-Opt-I.
   - **Electrobun**: devtools open automatically on launch in the
     benchmark build (we call `win.webview.openDevTools()` after
     window creation, because Electrobun's WKWebView has no
     right-click inspector menu).
4. Copy the entire contents of `benchmarks/bridge-bench.js` and paste
   into the devtools **Console** tab. Hit enter.
5. Wait ~1 second. Results print to the same console, plus a one-line
   JSON record you can copy into RESULTS.md.

Example output:

```
=== bridge bench ===
total:      6000 calls (30 batches × 200, 500 warmup)
min:        41.2 µs (fastest batch avg)
median:     44.8 µs (batch median)
mean:       45.1 µs (overall avg)
max:        52.6 µs (slowest batch avg)
stdev:      2.3 µs (across batches)
throughput: 22172 calls/sec (at mean)
json: {"total_calls":6000,"batches":30,"batch_size":200,"warmup":500,"min_us":41.2,"median_us":44.8,"mean_us":45.1,"max_us":52.6,"stdev_us":2.3,"throughput_per_sec":22172}
```

#### Devtools in release builds

Paste-into-console only works if the webview ships with the inspector
enabled. Each framework handles this differently:

- **Zapp**: inspector is on by default in both debug and release builds
  (`webContentInspectable: -1` in the benchmark apps inherits from the
  framework default of "on"). No config change needed.
- **Tauri**: v2 disables devtools in release unless the `devtools`
  Cargo feature is enabled. The benchmark app's `Cargo.toml` sets
  `tauri = { version = "2", features = ["devtools"] }` for exactly
  this reason. Production Tauri apps should omit the feature.
- **Wails**: v3 ships two sibling files —
  `webview_window_darwin_production.go` (empty `openDevTools(){}`
  stub) and `webview_window_darwin_dev.go` (real impl) — selected
  by Go build tag. `wails3 task darwin:package` compiles with
  `-tags production`, which picks the stub and makes *every* path
  to devtools a no-op: the `DevToolsEnabled` option, the
  `OpenInspectorOnStartup` option, `win.OpenDevTools()` calls, even
  the context menu. The only way to get devtools in a packaged
  Wails build is to drop the production tag via `DEV=true`, which
  also sets `-gcflags=all=-l` (disables Go inlining) —
  meaningfully different runtime characteristics.
  The benchmark handles this by measuring Wails **twice**:
  `build-all.sh` produces the production build for the fair
  size / startup / idle comparison; `build-wails-devtools.sh`
  rebuilds with DEV=true right before the IPC bench to unlock
  the inspector. The IPC result is recorded with a "DEV build"
  annotation so readers know it's on the slightly-deoptimized
  binary.
- **Electron**: devtools are enabled by default in `BrowserWindow`
  unless you explicitly disable them via `webPreferences.devTools`.
- **Electrobun**: devtools must be opened programmatically via
  `browserView.openDevTools()`. The benchmark app calls this 250 ms
  after window creation so the console is open when you need it.

## Methodology

### What we measure

| Column | How |
|---|---|
| **Binary** | `stat -f%z` on the main executable. For Electron's 52 KB launcher stub we hop to `Contents/Frameworks/Electron Framework.framework/...` and report the framework binary (~170 MB) since that's the real shippable weight. For Electrobun we report the compressed `.tar.zst` archive in `Contents/Resources/` (~17 MB) that ships on disk — the launcher stub itself is ~130 KB. This is noted in parentheses in the table. |
| **Bundle** | `du -sk` on the `.app` directory. This is the shipping weight measured **before first launch** — important for Electrobun, which grows its bundle from ~17 MB → ~69 MB on first launch by extracting `bun` and friends into `Contents/MacOS/`. |
| **Icon** | The largest `.icns` in `Contents/Resources/`. Worth its own column because Zapp's `iconutil`-generated multi-resolution icon dominates the bundle for small apps (2.4 MB of a 3 MB bundle is pure icon). |
| **Startup (ms)** | Wall-clock from `open -g -a <bundle>` dispatching to the PID being visible to `pgrep`, median of 15 runs after 5 warmups and a prime launch. This is a coarse bound — it doesn't wait for first paint — but the measurement is applied uniformly to every framework so the comparison is fair. |
| **Idle (MB)** | `footprint <pid>` output after a 3-second settle, **summed across every process tied to the bundle path**. This matters for multi-process frameworks: Electron runs a main + GPU helper + renderer helpers, Electrobun runs a launcher stub + a bun child. Summing gives a real total footprint, not just the main process. |

### Why `open -g -a`

Every framework is launched via `open -g -a <bundle>` rather than executing
`Contents/MacOS/<exe>` directly. This matters because Electron, Electrobun,
and others rely on the bundle context that LaunchServices sets up — code
signing checks, framework load paths, `__DATA` snapshots. Exec'ing the
stub binary bare causes Electron to crash in `v8::Context::FromSnapshot`.
`open` is the portable way to say "launch this like the OS would".

### Prime + warmup + measure

`bench.sh` runs three phases per app:

1. **Prime** — one launch with a 5-second settle window, to let
   self-extracting frameworks (Electrobun) finish unpacking. Every
   framework pays this cost equally; only Electrobun actually uses it.
2. **Warmups** — 5 untimed launches to prime disk cache and kernel code
   pages. Drops first-launch noise out of the measurement.
3. **Measured runs** — 15 timed launches, report the median.

After each launch, `kill_pid_tree` SIGTERMs every process referencing the
bundle path and spins up to 1 second waiting for them to actually die —
otherwise the next launch's `pgrep` picks up a dying zombie PID and the
idle measurement times out against a ghost process.

### Environment hygiene

Each `measure-all.sh` run records: date, hostname, macOS version, arch,
and the version of every framework involved. Framework versions are read
from the most authoritative source available:

- Zapp: git short SHA of the monorepo
- Tauri: the `tauri` crate entry in `Cargo.lock`
- Wails: `github.com/wailsapp/wails/v3` line in `go.mod`
- Electron: `electron` devDependency in `package.json`
- Electrobun: `electrobun` dependency in `package.json`

If a toolchain improves between runs, you can see it in the appended
`RESULTS.md` section without re-reading all the code.

### Fair-comparison invariants

- Every framework builds in **release** mode with its default profile. No
  hand-tuned `lto = true` / `opt-level = "z"` for Tauri — that would be
  unfair to Zapp, which uses Zen-C's stock release pipeline.
- Every framework uses its default packaging: `zc` for Zapp, `cargo tauri
  build` for Tauri, `wails3 task darwin:package` for Wails,
  `electron-forge package` for Electron, `electrobun build --env=stable`
  for Electrobun. No custom flags that would skew results.
- Every framework ships an adhoc signature only — no Apple Developer ID
  involvement, no entitlements customization, no hardened runtime beyond
  what defaults enable.
- Per-framework IPC uses each framework's idiomatic mechanism:
  `Services.invoke` for Zapp, `invoke("ping")` for Tauri, generated
  bindings for Wails, `ipcRenderer.invoke` for Electron, `defineRPC` +
  `rpc.request.ping()` for Electrobun.

## Layout

```
benchmarks/
├── README.md             # this file — methodology
├── RESULTS.md            # dated measurements, append-only
├── bench.sh              # single-app measurement script
├── bridge-bench.js       # paste-in-devtools IPC latency bench
├── apps/
│   ├── zapp-host-bridge/ # Zapp host-bridge bench across all engines
│   ├── tauri/            # Tauri v2 vanilla-ts scaffold
│   ├── wails/            # Wails v3 vanilla-ts scaffold
│   ├── electron/         # Electron + electron-forge
│   └── electrobun/       # Electrobun hello-world template
└── scripts/
    ├── build-all.sh      # one-shot build of every app
    └── measure-all.sh    # wraps bench.sh, appends to RESULTS.md
```

## What these benchmarks don't tell you

A fair word of caution before reading `RESULTS.md`:

- **Framework features differ wildly.** Electron gives you a full Chromium
  and Node. Electrobun gives you `Bun`. Tauri gives you a Rust backend.
  Wails gives you Go. Zapp gives you Zen-C. A hello-world measurement
  tells you about *overhead*, not about what each stack can build.
- **Startup methodology is coarse.** We measure process-visible, not
  first-paint. Frameworks that render off-thread may be undersold;
  frameworks that block the main thread on first paint may be oversold.
- **Idle memory is steady-state.** It doesn't reflect peak working set
  during heavy JS work, GC pressure, or WebGL usage.
- **Electrobun's "shipping" bundle grows on first launch.** The 17 MB
  figure in `bundle` is the download size; after extraction the bundle
  occupies ~69 MB on disk. Both are honest, just different numbers.
- **Windows is deferred.** All measurements here are macOS arm64. Windows
  benchmarks will land after macOS patterns are proven stable.

These caveats don't invalidate the numbers — they just set the right
expectations for what "Zapp is X MB" actually means.
