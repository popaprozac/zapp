# Dev-experience cleanup — logging/verbosity + build-manifest unification

**Date:** 2026-06-02
**Branch:** `feat/dev-experience`
**Surfaced by:** an iOS build failure (swallowed linker error) + log-noise complaint after the #150 `[zapp/<name>]` worker-log change left `[native]`/`[js-console]` inconsistent.

## Overview

Two related-but-independent themes, designed together (one clean dev experience), shipped as **two implementation plans**:

- **Part A — Logging & verbosity.** Kill the NSLog timestamp noise, unify the prefix taxonomy on `[zapp]` / `[zapp/<worker>]`, add a real `default` / `--verbose` / `--debug` level system that gates both CLI and native-app output, and stop swallowing build/linker errors.
- **Part B — Build-manifest unification.** Make `zapp.config.ts` the one declarative manifest (gains a typed `native:` block), reduce `build.zc` to pure Zen-C service code, and have the framework inject all platform boilerplate per target — eliminating the visible `_zapp_build_ios.zc` twin.

They share the goal (a clean, single-source dev experience) but touch different code (Part A: native log sites + CLI flags + `log()` impl; Part B: the CLI build-config/injector). Each produces working software on its own.

---

# Part A — Logging & verbosity

## Current state (verified)

- `log("…")` in `.zc` → `[native] …` via **NSLog**, which hard-prepends `2026-… procname[pid:tid]`. (e.g. `hello-world/zapp/app.zc:125`.)
- Worker `console.log` → `[js-console] …` (zjs.c:731 `fputs("[js-console]")`); bare uses `[bare:<id>]` (bare.c:509).
- Worker lifecycle/restart → `[zapp/<name>] …` (the good format from #150 WL T8, using `zapp_worker_registry_get_display_name`).
- CLI build/serve steps → scattered `process.stdout.write("[zapp] …")` in `zapp-cli.ts`.
- `--verbose` only gates the **zc compiler** output on `build` (native.ts:949); does nothing on `dev`. No `--debug`. No log-level concept.
- Build/linker failures are **swallowed**: the CLI prints `compilation failed — run with --verbose` and discards the real error (native.ts:1012-1017). This hid the iOS `Undefined symbols` error.

## Level model

Three levels, one model across the CLI and the running app:

| Level | Flag | Adds |
|---|---|---|
| **default** | (none) | condensed build/serve status; **the app's own output** (`[zapp]` app logs + `[zapp/<worker>]` worker console); all warnings + errors in full |
| **verbose** | `--verbose` / `-v` | + framework lifecycle (`[zapp] service registered`, `window created`, `event loop`, `app event: started`, …) |
| **debug** | `--debug` | + the zc compiler invocation, full linker output, internal framework detail |

Levels are cumulative (debug ⊇ verbose ⊇ default).

## How the level reaches both sides

- **CLI (TypeScript):** parse `--verbose` / `--debug` from argv once. A small `log` helper (replacing scattered `console.log`/`process.stdout.write`) carries a level per call; the CLI gates its own `[zapp] …` build-step lines accordingly.
- **Native app (the spawned binary):** the `[native]`/lifecycle/worker-console lines come from the running process, so the level must reach it. The CLI sets a **`ZAPP_LOG` env var** (`""`/unset = default, `verbose`, `debug`) when launching the dev app. Native code reads `ZAPP_LOG` once at startup into a global `zapp_log_level`; each native `log()` call site declares a level (most lifecycle = verbose; key milestones = default; errors = always). A production/packaged app is quiet by default, but `ZAPP_LOG=debug ./MyApp.app/Contents/MacOS/MyApp` turns on full logging in the field — no rebuild.

## Format changes

- **`log()` impl: NSLog → `fprintf(stderr, …)`** — drops the `timestamp procname[pid:tid]` prefix entirely. (Find the `log()` definition — a Zapp/Zen-C native logging function; it is NOT the zc-stdlib `math.log`. Confirmed `[native]` literal appears only at `ios/window.m:145`, so the prefix is added by the `log()` implementation, to be located during implementation.)
- **Unified taxonomy:** everything uses `[zapp]` (framework + app-level) or `[zapp/<worker>]` (per-worker). `[native]` and `[js-console]` and `[bare:<id>]` are removed.
- **Worker console auto-prefix:** the worker engine prefixes console output with the worker's display name → `[zapp/<worker>]` (zjs.c:731 and bare.c:509 both updated to use `zapp_worker_registry_get_display_name`). hello-world's workers stop self-labeling (`console.log("[ticker] started")` → `console.log("started")`) so output reads `[zapp/ticker] started`, not `[zapp/ticker] [ticker] started`.

## Error surfacing

Build/linker/compiler failures **print their real output by default** — never swallowed. The `compilation failed — run with --verbose` message is replaced by the actual error (e.g. the `Undefined symbols` block). `--debug` additionally prints the full compiler/linker invocation. (Fixes the exact friction that hid the iOS zlib link error.)

## Part A non-goals

- No log file / rotation / structured (JSON) logging — stderr text only.
- No per-category filtering (e.g. "only worker logs") — just the three cumulative levels.
- No change to the worker→host IPC or the runtime `console` semantics inside workers (only the host-side print prefix changes).

---

# Part B — Build-manifest unification

## Current state (verified)

- `zapp.config.ts` holds app config (name/identifier/version/headless/workerModules/webEngine).
- `zapp/build.zc` holds: service registrations (Zen-C handlers) + `//> <platform>: framework:/link:` directives + worker-engine selection.
- iOS builds generate `_zapp_build_ios.zc` (build-config.ts:213 `generateIOSBuildFile`) — a transformed copy of `build.zc` written **into `zapp/`** (visible), swapping Cocoa→UIKit, dropping Carbon, setting sysroot/arch/min-version, substituting the iOS engine, adding link flags. Gitignored but visible clutter and a conceptual twin.
- The injector already partially exists (#153 auto-injects required frameworks/flags; #135 auto-builds the default engine; #152 warns on an unused engine).

## B1 — `zapp.config.ts` gains a typed `native` block

```ts
native?: {
  frameworks?: string[];  // extra system frameworks, e.g. ["CoreLocation", "Contacts"]
  linkFlags?: string[];   // extra -l / -L / raw linker flags
  sources?: string[];     // extra .m / .c / .zc files to compile in
};
```

This is the Tauri-style native-linking surface — typed + autocompleted, one place. (Cleaner than Tauri's `Cargo.toml` + `build.rs` + `tauri.conf.json` split.)

## B2 — `build.zc` becomes pure service code

The default `zapp init` template and hello-world's `build.zc` carry **only** the Zen-C service handlers + their `app.service.add(...)` registrations — no `//> framework:` / `//> link:` platform directives, no `ZAPP_WORKER_ENGINE_*` defines.

**Raw `//>` directives remain a supported escape hatch:** the zc compiler still scans them wherever a power user adds them (`build.zc` or any `.zc`), and the injector merges them in. Native-first devs are never blocked; the `native:` block is just the friendly primary surface.

## B3 — The injector (single source of build truth)

In `cli/src/build-config.ts` / `native.ts`, per active target (`macos` / `ios-simulator` / `ios-device` / `windows`):

1. **Derive compiled engines** from the workers' `engine:` fields in `zapp.config.ts` (headless + the auto-discovered-worker default) — no manual engine defines in `build.zc`.
2. **Compute platform defaults:**
   - macOS: Cocoa, WebKit, JavaScriptCore, Security, Carbon, UserNotifications + `-lcompression -lz`.
   - iOS: UIKit, Foundation, WebKit, JavaScriptCore, UniformTypeIdentifiers, UserNotifications + sysroot/arch/min-version + `-lcompression -lz`.
   - Windows: its existing link set.
3. **Merge** platform defaults + `zapp.config.ts` `native:` extras + any raw `//>` directives.
4. **Feed the compiler** these directives per target. Preferred: pass them as compiler args so there is **no generated build-manifest file on disk**. Fallback: if the zc compiler requires a manifest file, write it to the hidden `.zapp/` dir (where worker bundles already live), never `zapp/`. (Which path — settled during implementation by checking whether `zc` accepts the directives as args; the user-facing outcome is identical: no visible twin.)

The visible `_zapp_build_ios.zc` is eliminated either way.

## B4 — Back-compat & migration

- Existing `build.zc` files that still carry `//> macos:` directives keep working — the injector merges them with the auto-computed defaults (redundant but harmless; deduped where trivial).
- `zapp init` templates stop emitting platform directives + engine defines in `build.zc`.
- No existing project breaks; the change is additive (config gains `native:`; build.zc directives become optional rather than required).

## B5 — `native:` validation

The CLI validates the `native:` block (arrays of strings; unknown keys warned) the same way it validates the rest of `zapp.config.ts`. Malformed values produce a clear CLI error, not a raw compiler failure.

## Part B non-goals

- No package-manager-style native dependency fetching (no "add CocoaPod / SwiftPM dep") — `native:` is frameworks/flags/sources the developer already has, not a fetcher.
- No removal of the raw `//>` directive mechanism (it stays as the escape hatch).
- No Windows-specific manifest work beyond moving its existing link set into the injector (Windows parity is its own track, #167).

---

## Verification (both parts)

Native builds have no unit harness for these layers; verify by build + manual observation (the repo's convention), plus the new `bun test` suite where pure TS logic is added (the CLI `log` helper + the `native:` merge/validation are pure-function-testable).

**Part A:**
1. `bun run dev` (default) → clean output: condensed status + `[zapp/ticker] started` etc. + no `[native]` timestamps, no `[js-console]`, no per-step framework lifecycle.
2. `bun run dev --verbose` → adds the framework lifecycle lines (now `[zapp] …`, no NSLog prefix).
3. `bun run dev --debug` → adds zc compiler output.
4. Force a build error (e.g. a bad link flag) → the real error prints by default (not swallowed).
5. `ZAPP_LOG=debug` on a packaged app → full logging without rebuild.

**Part B:**
1. A `build.zc` with no platform directives + no engine defines still builds on macOS and iOS.
2. `zapp.config.ts` `native: { frameworks: ["CoreLocation"] }` → CoreLocation linked (verify it appears in the compiler invocation under `--debug`).
3. `zapp/` no longer contains `_zapp_build_ios.zc` after an iOS build.
4. A raw `//> link: -lfoo` left in `build.zc` is still honored (escape hatch).
5. An existing project with legacy `//> macos:` directives still builds (back-compat).

## Related

- [[project_workers_list_cycle]] — #150 WL T8 introduced the `[zapp/<name>]` format this unifies on.
- [[reference_unusernotificationcenter_bundle_guard]] / [[reference_wkwebview_teardown]] — native macOS lifecycle work, same area as the `log()` change.
- [[feedback_native_first]] / [[feedback_native_first_implementation]] — the raw `//>` escape hatch preserves native-first privilege.
- [[feedback_verify_native_build]] — the build-verify rule; note Part A changes the success-line plumbing, so re-confirm the `[zapp] build complete:` last-line check still holds.
- iOS `-lz` fix (merged `73720b5`) — the concrete bug that motivated Part B's injector owning platform link flags.
