# N0 — Platform Runtime API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Round out the runtime `Platform` export with `formFactor` (phone/tablet/desktop) and `env` (dev/prod) alongside the existing `os`, with both string and boolean accessors, sourced native-first.

**Architecture:** `runtime/platform.ts` reads three values off the per-webview `globalThis[Symbol.for("zapp.bootstrapConfig")]`: `os` from the existing `permissions.platform` (build-time), and NEW top-level `formFactor` + `env` injected by the native bootstrapConfig carrier (`darwin/webview.m` + `ios/webview.m` + Windows). `os`/`env` are build-time; `formFactor` is runtime (iOS device idiom). Back-compat: existing `current()`/`isMacOS`/`isIOS`/`isWindows` unchanged.

**Tech Stack:** TypeScript (runtime), Objective-C (darwin/iOS WKUserScript injection), C (Windows), Bun (tests/build).

## Global Constraints

- Branch `feat/ios-native-nav` — commit directly. NO worktree, NO `git commit --amend`, NO merge.
- Commit trailer EXACTLY: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- Per-file `git add` only — never `-A`/`.`. Pre-existing unrelated WIP stays unstaged.
- Bun, never Node.
- Native-first parity: native source → bootstrapConfig carrier → runtime → docs, same PR.
- macOS is the parity reference. NO iOS simulator interaction in-session (build-only gates + human smoke).
- iPad = `os:"ios"` + `formFactor:"tablet"` (NO `"ipados"`). Defaults when config absent: `os→"macos"`, `formFactor→"desktop"`, `env→"prod"`.
- Out of scope: `Platform` in workers (deferred to N2); `"ipados"`; size-class granularity.

Per-task gates: `bun run check`; `bun test cli/src`; `bun run test:native`; iOS compile (`cd kitchen-sink && bun run build --platform ios` → `[zapp] build complete:`); macOS build (`cd kitchen-sink && bun run build` → `[zapp] build complete:`).

## File Structure

| File | Responsibility |
|---|---|
| `runtime/platform.ts` | the `Platform` surface — os/formFactor/env getters + booleans, reading the config with safe defaults. |
| `runtime/platform.test.ts` | unit tests for all three axes + defaults. |
| `runtime/index.ts` | export the new `FormFactor` / `AppEnv` types. |
| `native/platform/darwin/webview.m` | inject `formFactor:'desktop'` + `env` into the bootstrapConfig. |
| `native/platform/ios/webview.m` | inject `formFactor` (device idiom) + `env`. |
| `native/platform/windows/webview.c` | inject `formFactor:'desktop'` + `env` (parity). |
| `docs/api-reference.md` | document the rounded-out `Platform`. |

---

## Task 1: Runtime `Platform` surface (TDD, pure)

**Files:**
- Modify: `runtime/platform.ts` (whole file, currently 22 lines)
- Modify: `runtime/index.ts:36` (type exports)
- Test: `runtime/platform.test.ts`

**Interfaces:**
- Consumes: `globalThis[Symbol.for("zapp.bootstrapConfig")]` shape `{ permissions?: { platform?: "macos"|"ios"|"windows" }, formFactor?: "phone"|"tablet"|"desktop", env?: "dev"|"prod" }`. The `formFactor`/`env` fields are wired by Task 2; this task reads them with safe defaults so it stands alone.
- Produces: `Platform.os`/`formFactor`/`env` + `isMacOS`/`isIOS`/`isWindows`/`isPhone`/`isTablet`/`isDesktop`/`isDev`/`isProd` + existing `current()`; types `FormFactor`, `AppEnv`.

- [ ] **Step 1: Write the failing tests** — append to `runtime/platform.test.ts` (keep the existing 3 tests):

```ts
test("Platform.os mirrors current()", () => {
  (globalThis as any)[BOOT] = { permissions: { platform: "ios" } };
  expect(Platform.os).toBe("ios");
  delete (globalThis as any)[BOOT];
});

test("Platform.formFactor + booleans read the injected formFactor", () => {
  (globalThis as any)[BOOT] = { permissions: { platform: "ios" }, formFactor: "tablet" };
  expect(Platform.formFactor).toBe("tablet");
  expect(Platform.isTablet).toBe(true);
  expect(Platform.isPhone).toBe(false);
  expect(Platform.isDesktop).toBe(false);
  delete (globalThis as any)[BOOT];
});

test("Platform.formFactor defaults to desktop when absent", () => {
  (globalThis as any)[BOOT] = { permissions: { platform: "macos" } };
  expect(Platform.formFactor).toBe("desktop");
  expect(Platform.isDesktop).toBe(true);
  delete (globalThis as any)[BOOT];
});

test("Platform.env + booleans read the injected env", () => {
  (globalThis as any)[BOOT] = { permissions: { platform: "ios" }, env: "dev" };
  expect(Platform.env).toBe("dev");
  expect(Platform.isDev).toBe(true);
  expect(Platform.isProd).toBe(false);
  delete (globalThis as any)[BOOT];
});

test("Platform.env defaults to prod when absent", () => {
  delete (globalThis as any)[BOOT];
  expect(Platform.env).toBe("prod");
  expect(Platform.isProd).toBe(true);
});
```

- [ ] **Step 2: Run, verify they fail**

Run: `bun test runtime/platform.test.ts`
Expected: FAIL — `Platform.os`/`formFactor`/`env` undefined.

- [ ] **Step 3: Rewrite `runtime/platform.ts`** to:

```ts
/**
 * Runtime platform/form-factor/environment for conditional app logic.
 *
 * Reads the per-webview bootstrap manifest injected natively
 * (`globalThis[Symbol.for("zapp.bootstrapConfig")]`):
 *   - os  ← permissions.platform (build-time target)
 *   - formFactor ← top-level formFactor (runtime; iOS device idiom; "desktop" on desktop)
 *   - env ← top-level env (build-time dev/prod)
 * Safe defaults when absent (SSR/tests/older native): os "macos", formFactor
 * "desktop", env "prod".
 */
export type PlatformName = "macos" | "ios" | "windows";
export type FormFactor = "desktop" | "phone" | "tablet";
export type AppEnv = "dev" | "prod";

function cfg(): any {
  return (globalThis as any)[Symbol.for("zapp.bootstrapConfig")];
}
function readOS(): PlatformName {
  const p = cfg()?.permissions?.platform;
  return p === "ios" || p === "windows" ? p : "macos";
}
function readFormFactor(): FormFactor {
  const f = cfg()?.formFactor;
  return f === "phone" || f === "tablet" ? f : "desktop";
}
function readEnv(): AppEnv {
  return cfg()?.env === "dev" ? "dev" : "prod";
}

export const Platform = {
  current(): PlatformName { return readOS(); },
  get os(): PlatformName { return readOS(); },
  get isMacOS(): boolean { return readOS() === "macos"; },
  get isIOS(): boolean { return readOS() === "ios"; },
  get isWindows(): boolean { return readOS() === "windows"; },
  get formFactor(): FormFactor { return readFormFactor(); },
  get isPhone(): boolean { return readFormFactor() === "phone"; },
  get isTablet(): boolean { return readFormFactor() === "tablet"; },
  get isDesktop(): boolean { return readFormFactor() === "desktop"; },
  get env(): AppEnv { return readEnv(); },
  get isDev(): boolean { return readEnv() === "dev"; },
  get isProd(): boolean { return readEnv() === "prod"; },
};
```

- [ ] **Step 4: Export the new types** — `runtime/index.ts:36` currently:

```ts
export { Platform, type PlatformName } from "./platform";
```
Change to:
```ts
export { Platform, type PlatformName, type FormFactor, type AppEnv } from "./platform";
```

- [ ] **Step 5: Run tests, verify pass**

Run: `bun test runtime/platform.test.ts`
Expected: PASS (all — 3 existing + 5 new).

- [ ] **Step 6: Gates** — `bun run check`; `bun test cli/src` (both pass).

- [ ] **Step 7: Commit**

```bash
git add runtime/platform.ts runtime/platform.test.ts runtime/index.ts
git commit -m "$(cat <<'EOF'
feat(platform): add formFactor + env to the runtime Platform API

os (build-time) + formFactor (phone/tablet/desktop) + env (dev/prod), string +
boolean accessors, reading bootstrapConfig with safe defaults. Back-compat:
current()/isMacOS/isIOS/isWindows unchanged. Native wiring lands in Task 2.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Native carrier injection + docs + smoke

**Files:**
- Modify: `native/platform/darwin/webview.m` (configScript ~line 924)
- Modify: `native/platform/ios/webview.m` (configScript ~line 809)
- Modify: `native/platform/windows/webview.c` (the equivalent bootstrapConfig injection)
- Modify: `docs/api-reference.md` (Platform section)

**Interfaces:**
- Consumes: `extern int zapp_build_is_dev(void);` — already declared + used in `darwin/webview.m:32` and `ios/webview.m:63`.
- Produces: `bootstrapConfig.formFactor` (`"desktop"`|`"phone"`|`"tablet"`) + `bootstrapConfig.env` (`"dev"`|`"prod"`) — read by Task 1's `Platform`.

- [ ] **Step 1: macOS carrier** — `native/platform/darwin/webview.m`, the `configScript` format (~line 924). Current format string + args:

```objc
    NSString* configScript = [NSString stringWithFormat:
        @"(function(){globalThis[Symbol.for('zapp.bootstrapConfig')]="
        "{name:'%@',applicationShouldTerminateAfterLastWindowClosed:%@,"
        "webContentInspectable:%@,maxWorkers:%d,theme:'%@',powerState:%s,permissions:%s%@};})();",
        appName,
        terminate ? @"true" : @"false",
        inspect ? @"true" : @"false",
        maxWorkers, themeStr, powerStateC, permsJson, cspExtra];
```

Insert `formFactor:'desktop',env:'%@',` before `permissions:%s`, and the matching arg (a new `%@`) before `permsJson`:

```objc
    NSString* configScript = [NSString stringWithFormat:
        @"(function(){globalThis[Symbol.for('zapp.bootstrapConfig')]="
        "{name:'%@',applicationShouldTerminateAfterLastWindowClosed:%@,"
        "webContentInspectable:%@,maxWorkers:%d,theme:'%@',powerState:%s,"
        "formFactor:'desktop',env:'%@',permissions:%s%@};})();",
        appName,
        terminate ? @"true" : @"false",
        inspect ? @"true" : @"false",
        maxWorkers, themeStr, powerStateC,
        (zapp_build_is_dev() ? @"dev" : @"prod"),
        permsJson, cspExtra];
```

- [ ] **Step 2: iOS carrier** — `native/platform/ios/webview.m`, the `configScript` format (~line 809). Current:

```objc
    NSString* configScript = [NSString stringWithFormat:
        @"(function(){globalThis[Symbol.for('zapp.bootstrapConfig')]="
        "{name:'%@',applicationShouldTerminateAfterLastWindowClosed:%@,"
        "webContentInspectable:%@,maxWorkers:%d,theme:'%@',powerState:%s,permissions:%s};})();",
        appName, terminate ? @"true" : @"false", inspect ? @"true" : @"false",
        maxWorkers, themeStr, darwin_get_power_state(), permsJson];
```

Add a form-factor local (device idiom) just above the configScript, then inject `formFactor:'%@',env:'%@',`:

```objc
    // formFactor: runtime device idiom (iPad → "tablet", else "phone").
    NSString* ffStr = (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad)
        ? @"tablet" : @"phone";
    NSString* configScript = [NSString stringWithFormat:
        @"(function(){globalThis[Symbol.for('zapp.bootstrapConfig')]="
        "{name:'%@',applicationShouldTerminateAfterLastWindowClosed:%@,"
        "webContentInspectable:%@,maxWorkers:%d,theme:'%@',powerState:%s,"
        "formFactor:'%@',env:'%@',permissions:%s};})();",
        appName, terminate ? @"true" : @"false", inspect ? @"true" : @"false",
        maxWorkers, themeStr, darwin_get_power_state(),
        ffStr, (zapp_build_is_dev() ? @"dev" : @"prod"),
        permsJson];
```

- [ ] **Step 3: Windows carrier (parity)** — find the bootstrapConfig injection in `native/platform/windows/webview.c` (`grep -n "bootstrapConfig" native/platform/windows/webview.c`). If present, add `formFactor:'desktop',env:'...'` to the injected object the same way (env from `zapp_build_is_dev()` — confirm/add `extern int zapp_build_is_dev(void);` if not already declared there). If the Windows carrier does NOT yet inject a bootstrapConfig, do nothing and note it in the report (Windows runtime defaults to desktop/prod, which is correct). Windows is not a smoke target this cycle.

- [ ] **Step 4: Build gates**

Run: `cd kitchen-sink && bun run build` → expect `[zapp] build complete:` (macOS).
Run: `cd kitchen-sink && bun run build --platform ios` → expect `[zapp] build complete:` (iOS).
Run: `bun run check`; `bun test cli/src`; `bun run test:native` (all pass — no TS/Nim logic change here).

- [ ] **Step 5: Document** — `docs/api-reference.md`, the Platform section (`grep -n "Platform" docs/api-reference.md`). Document the rounded-out surface: `Platform.os` / `formFactor` (`"desktop"|"phone"|"tablet"`) / `env` (`"dev"|"prod"`); the booleans `isMacOS`/`isIOS`/`isWindows`/`isPhone`/`isTablet`/`isDesktop`/`isDev`/`isProd`; that **iPad reports `os:"ios"` + `formFactor:"tablet"`** (no `"ipados"`); values are injected native-first; `Platform` is webview-only today (workers: a later cycle). Match the surrounding doc prose style with a short example (`if (Platform.isIOS && Platform.isPhone) { … }`).

- [ ] **Step 6: Commit**

```bash
git add native/platform/darwin/webview.m native/platform/ios/webview.m native/platform/windows/webview.c docs/api-reference.md
git commit -m "$(cat <<'EOF'
feat(platform): inject formFactor + env into the bootstrapConfig carrier

darwin/windows inject formFactor:"desktop"; iOS injects the device idiom
(UIUserInterfaceIdiomPad → "tablet", else "phone"); all inject env from
zapp_build_is_dev(). Powers Platform.formFactor/env. Docs updated.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

(If Windows has no bootstrapConfig injection, stage only the three files actually changed.)

- [ ] **Step 7: HUMAN SMOKE GATE**

STOP for human smoke (controller/user runs it; no in-session sim):
- **macOS:** a readout (tiny kitchen-sink log/section or devtools console) shows `Platform.os==="macos"`, `Platform.formFactor==="desktop"`, and `Platform.env` matching the build (`"dev"` under `bun run dev`, `"prod"` under a prod build).
- **iOS:** `Platform.os==="ios"`, `Platform.formFactor==="phone"` on iPhone and `"tablet"` on iPad.

---

## Self-Review

**Spec coverage:** os/formFactor/env + string & boolean accessors (Task 1); native-first injection darwin/ios/windows (Task 2); back-compat (Task 1 keeps existing surface); defaults (Task 1 readers); iPad=ios+tablet (Task 2 iOS idiom + docs); workers deferred (Global Constraints, not implemented). All spec sections covered.

**Placeholder scan:** none — exact format-string edits + full new platform.ts shown. The one conditional ("if Windows injection exists") is a concrete, decidable instruction with a defined fallback, not a placeholder.

**Type consistency:** `FormFactor`="desktop"|"phone"|"tablet" and `AppEnv`="dev"|"prod" identical across platform.ts, the wire strings injected natively (`'desktop'`/`'phone'`/`'tablet'`, `'dev'`/`'prod'`), and index.ts exports. Config field names `formFactor`/`env` match between Task 2 (writer) and Task 1 (reader).
