# N2c — Platform (os/formFactor/env) in Workers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make `@zappdev/runtime`'s `Platform` (os/formFactor/env + their booleans) honest inside worker code, with full parity to the webview, by carrying a `bootstrapConfig` into every worker via the native `__zappBridge`.

**Architecture:** Native is the source of truth. Each worker engine (`zjs.c` + `bare.c`) sets three string props on the per-worker `__zappBridge` — `permissions` (the existing `permissions_bootstrap_json()`, contains `platform`→os), `env` (`zapp_build_is_dev()`), `formFactor` (a new native `zapp_form_factor()`). `bootstrap/worker.ts` publishes them as `globalThis[Symbol.for("zapp.bootstrapConfig")]`, the same shape the webview's WKUserScript builds. Zero `platform.ts` change. `webview.m` adopts `zapp_form_factor()` too so webview/worker can't drift.

**Tech Stack:** ObjC (.m) + C (engines), TypeScript (bootstrap + runtime test), Bun.

## Global Constraints

- Branch `feat/ios-native-nav` — commit directly. NO git worktree, NO `git commit --amend`, NO merge.
- Commit trailer EXACTLY: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- Per-file `git add` ONLY — never `-A`/`.`. Pre-existing unrelated WIP stays unstaged.
- Bun, never Node.
- Native-first parity: mirror the webview carrier shape; worker-engine parity (zjs **and** bare both set the props).
- macOS is the testable reference; iOS must keep COMPILING (`zapp_form_factor()` needs both darwin + ios defs since zjs/bare compile for both). NO iOS simulator interaction in-session.
- Spec: `docs/superpowers/specs/2026-06-28-n2c-worker-platform-design.md`.

Per-task gates: `bun run check`; `bun test cli/src`; `bun run test:native`; macOS build (`cd kitchen-sink && bun run build` → `[zapp] build complete:`); iOS compile (`cd kitchen-sink && bun run build --platform ios` → `[zapp] build complete:`). T1 also `bun test runtime/platform.test.ts`.

## Reference map (exact sites, from exploration)

- `runtime/platform.ts` reads `cfg()?.permissions?.platform` (os), `cfg()?.formFactor`, `cfg()?.env`; defaults `macos`/`desktop`/`prod`. **No change** (doc-comment only).
- Webview carrier shape (`darwin/webview.m` ~919–934): `{name,…,formFactor:'desktop',env:'<dev|prod>',permissions:<permissions_bootstrap_json()>}`. iOS (`ios/webview.m` ~805–818): same, but `formFactor` from `UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ? @"tablet" : @"phone"` (the value `zapp_form_factor()` must reproduce on iOS).
- `zjs.c` string prop: `ZjsValue v = zjs_new_string(ctx, cstr, (uint32_t)strlen(cstr)); zjs_set_property(ctx, bridge, "name", v);` — workerId set at **zjs.c:1022**, just before `zjs_set_global(ctx, "__zappBridge", bridge)` (1023).
- `bare.c` string prop: `js_value s; js_create_string_utf8(slot->env, (const utf8_t*)cstr, strlen(cstr), &s); js_set_named_property(slot->env, bridge, "name", s);` — workerId set at **bare.c:1715** (mirror its exact local type/helper).
- Externs already present: `webview.m` has `extern int zapp_build_is_dev(void);` + `extern const char* permissions_bootstrap_json(void);`. Engines `extern` generated symbols already.
- Platform accessor home: `native/platform/darwin/platform.m` (has `darwin_get_power_state`) + `native/platform/ios/platform.m` (`ZappAppDelegate`, `didFinishLaunchingWithOptions:` at ios/platform.m:228).
- `bootstrap/worker.ts` IIFE head: `const bridge = (self as any).__zappBridge; if (!bridge) return;` (lines 27–28).
- `runtime/platform.test.ts`: mock by `(globalThis as any)[Symbol.for("zapp.bootstrapConfig")] = {...}` then assert then `delete`.

---

## Task 1: Native carrier + bootstrap publish + contract test

**Files:**
- Create the accessor: `native/platform/darwin/platform.m` (add `zapp_form_factor` returning `"desktop"`), `native/platform/ios/platform.m` (add `zapp_form_factor` + launch capture).
- Modify: `native/platform/darwin/webview.m`, `native/platform/ios/webview.m` (adopt `zapp_form_factor()`).
- Modify: `native/worker/engines/zjs.c`, `native/worker/engines/bare.c` (three props on `__zappBridge`).
- Modify: `bootstrap/worker.ts` (publish `bootstrapConfig`).
- Modify: `runtime/platform.ts` (doc-comment only).
- Test: `runtime/platform.test.ts` (worker-shape contract case).

**Interfaces:**
- Produces (consumed by Task 2 + the runtime): `extern const char* zapp_form_factor(void)` (`"desktop"`|`"phone"`|`"tablet"`); each worker's `__zappBridge` carries string props `permissions`, `env`, `formFactor`; `globalThis[Symbol.for("zapp.bootstrapConfig")]` is set in every worker.

- [ ] **Step 1: Add the worker-shape contract test** — in `runtime/platform.test.ts`, append (matches the file's set/assert/delete style):

```ts
test("Platform reads a worker-shaped bootstrapConfig (os + formFactor + env)", () => {
  (globalThis as any)[Symbol.for("zapp.bootstrapConfig")] = {
    permissions: { platform: "ios" },
    formFactor: "phone",
    env: "dev",
  };
  expect(Platform.os).toBe("ios");
  expect(Platform.isIOS).toBe(true);
  expect(Platform.formFactor).toBe("phone");
  expect(Platform.isPhone).toBe(true);
  expect(Platform.env).toBe("dev");
  expect(Platform.isDev).toBe(true);
  delete (globalThis as any)[Symbol.for("zapp.bootstrapConfig")];
});

test("Platform defaults hold when no config (worker before/without carrier)", () => {
  delete (globalThis as any)[Symbol.for("zapp.bootstrapConfig")];
  expect(Platform.os).toBe("macos");
  expect(Platform.formFactor).toBe("desktop");
  expect(Platform.env).toBe("prod");
});
```

- [ ] **Step 2: Run it — PASS** (`platform.ts` already reads this shape; the test locks the contract the native side must produce).

Run: `bun test runtime/platform.test.ts`
Expected: PASS (all cases, incl. the two new).

- [ ] **Step 3: Add `zapp_form_factor()` — darwin.** In `native/platform/darwin/platform.m`, add (near the other `darwin_*` accessors):

```objc
// Form factor for Platform.formFactor. macOS is always "desktop". Shared by
// the webview config script (webview.m) and the worker engines (zjs/bare) so
// the value can never drift between contexts. Mirrored on iOS (ios/platform.m).
const char* zapp_form_factor(void) { return "desktop"; }
```

- [ ] **Step 4: Add `zapp_form_factor()` — iOS (capture at launch).** In `native/platform/ios/platform.m`:
  - Add a file-scope static + accessor (near the other accessors):
    ```objc
    // Device idiom captured once at launch (main thread) into a process global,
    // so zapp_form_factor() is cheap + thread-safe to read from a worker pthread.
    // "tablet" on iPad, else "phone". Default "phone" until launch captures it.
    static const char* g_zapp_form_factor = "phone";
    const char* zapp_form_factor(void) { return g_zapp_form_factor; }
    ```
  - Inside `- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(...)` (ios/platform.m:228), at the top of the body, add:
    ```objc
    g_zapp_form_factor = (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) ? "tablet" : "phone";
    ```

- [ ] **Step 5: darwin `webview.m` adopts `zapp_form_factor()`.** In `native/platform/darwin/webview.m`:
  - Add to the externs (near `extern int zapp_build_is_dev(void);`): `extern const char* zapp_form_factor(void);`
  - In the config `WKUserScript` `stringWithFormat` (~927): change the literal `formFactor:'desktop'` to `formFactor:'%s'`, and insert `zapp_form_factor()` into the argument list at the matching position — immediately after `powerStateC` and before `(zapp_build_is_dev() ? @"dev" : @"prod")`. Result:
    ```objc
        @"...powerState:%s,"
        "formFactor:'%s',env:'%@',permissions:%s%@};})();",
        appName, terminate ? @"true" : @"false", inspect ? @"true" : @"false",
        maxWorkers, themeStr, powerStateC,
        zapp_form_factor(),
        (zapp_build_is_dev() ? @"dev" : @"prod"),
        permsJson, cspExtra];
    ```
    (macOS value is unchanged — `zapp_form_factor()` returns `"desktop"`.)

- [ ] **Step 6: iOS `webview.m` adopts `zapp_form_factor()`.** In `native/platform/ios/webview.m`:
  - Add to the externs (near `extern int zapp_build_is_dev(void);`): `extern const char* zapp_form_factor(void);`
  - Replace the inline idiom computation (~808–809, `NSString* ffStr = (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) ? @"tablet" : @"phone";`) with:
    ```objc
    NSString* ffStr = [NSString stringWithUTF8String:zapp_form_factor()];
    ```
    (The `formFactor:'%@'` + `ffStr` usage is unchanged; the value is identical — same idiom logic, now via the shared accessor.)

- [ ] **Step 7: zjs.c sets the three props.** In `native/worker/engines/zjs.c`, immediately after the workerId set (line 1022) and before `zjs_set_global(ctx, "__zappBridge", bridge)` (1023), add:

```c
    // N2c: carry Platform os/formFactor/env into the worker via __zappBridge,
    // mirroring the webview's bootstrapConfig. bootstrap/worker.ts reads these
    // and publishes globalThis[Symbol.for("zapp.bootstrapConfig")].
    {
        extern const char* permissions_bootstrap_json(void);
        extern int zapp_build_is_dev(void);
        extern const char* zapp_form_factor(void);
        const char* perms = permissions_bootstrap_json();
        if (!perms || !perms[0]) perms = "{\"platform\":\"macos\",\"active\":false,\"allow\":[]}";
        const char* envc = zapp_build_is_dev() ? "dev" : "prod";
        const char* ffc = zapp_form_factor();
        ZjsValue perms_str = zjs_new_string(ctx, perms, (uint32_t) strlen(perms));
        zjs_set_property(ctx, bridge, "permissions", perms_str);
        ZjsValue env_str = zjs_new_string(ctx, envc, (uint32_t) strlen(envc));
        zjs_set_property(ctx, bridge, "env", env_str);
        ZjsValue ff_str = zjs_new_string(ctx, ffc, (uint32_t) strlen(ffc));
        zjs_set_property(ctx, bridge, "formFactor", ff_str);
    }
```

- [ ] **Step 8: bare.c sets the three props.** In `native/worker/engines/bare.c`, immediately after the workerId set (line 1715), add (mirror the local `js_value` type + `js_create_string_utf8` signature used for `worker_id_str` just above 1715):

```c
    // N2c: Platform os/formFactor/env carrier (mirror of zjs.c + the webview).
    {
        extern const char* permissions_bootstrap_json(void);
        extern int zapp_build_is_dev(void);
        extern const char* zapp_form_factor(void);
        const char* perms = permissions_bootstrap_json();
        if (!perms || !perms[0]) perms = "{\"platform\":\"macos\",\"active\":false,\"allow\":[]}";
        const char* envc = zapp_build_is_dev() ? "dev" : "prod";
        const char* ffc = zapp_form_factor();
        js_value perms_str, env_str, ff_str;
        js_create_string_utf8(slot->env, (const utf8_t*)perms, strlen(perms), &perms_str);
        js_set_named_property(slot->env, bridge, "permissions", perms_str);
        js_create_string_utf8(slot->env, (const utf8_t*)envc, strlen(envc), &env_str);
        js_set_named_property(slot->env, bridge, "env", env_str);
        js_create_string_utf8(slot->env, (const utf8_t*)ffc, strlen(ffc), &ff_str);
        js_set_named_property(slot->env, bridge, "formFactor", ff_str);
    }
```
(If the existing `worker_id_str` uses a different `js_value` spelling, match it exactly.)

- [ ] **Step 9: bootstrap/worker.ts publishes `bootstrapConfig`.** In `bootstrap/worker.ts`, immediately after `if (!bridge) return;` (line 28), insert:

```ts
  // N2c: publish the Platform bootstrapConfig from the native-supplied bridge
  // props (os/formFactor/env), mirroring the webview's WKUserScript carrier so
  // @zappdev/runtime's Platform works in worker code. Defaults match platform.ts.
  (globalThis as any)[Symbol.for("zapp.bootstrapConfig")] = {
    permissions: JSON.parse((bridge as any).permissions || '{"platform":"macos","active":false,"allow":[]}'),
    formFactor: (bridge as any).formFactor || "desktop",
    env: (bridge as any).env || "prod",
  };
```

- [ ] **Step 10: platform.ts doc-comment.** In `runtime/platform.ts`, update the header comment so the "Reads the per-webview bootstrap manifest" line also notes workers: e.g. change "Reads the per-webview bootstrap manifest injected natively" to "Reads the bootstrap manifest injected natively — by the webview's WKUserScript, or, in a worker, published by `bootstrap/worker.ts` from the native `__zappBridge` (os/formFactor/env)". No code change.

- [ ] **Step 11: Full gates.** Run: `bun test runtime/platform.test.ts`; `bun run check`; `bun test cli/src`; `bun run test:native`; `cd kitchen-sink && bun run build` (expect `[zapp] build complete:`); `cd kitchen-sink && bun run build --platform ios` (expect `[zapp] build complete:`). The iOS compile is the gate for the `webview.m` formFactor refactor + the `zjs.c`/`bare.c`/`ios/platform.m` calls into `zapp_form_factor()`.

- [ ] **Step 12: Commit.**
```bash
git add native/platform/darwin/platform.m native/platform/ios/platform.m native/platform/darwin/webview.m native/platform/ios/webview.m native/worker/engines/zjs.c native/worker/engines/bare.c bootstrap/worker.ts runtime/platform.ts runtime/platform.test.ts
git commit  # message below, with the required trailer
```
Message: `feat(platform): carry Platform os/formFactor/env into workers via __zappBridge`

---

## Task 2: Kitchen-sink worker readout + docs + macOS human smoke

**Files:**
- Modify: `kitchen-sink/src/worker.ts`
- Modify: `docs/api-reference.md`

**Interfaces:**
- Consumes (from Task 1): `Platform.os`/`formFactor`/`env` now valid in worker code.

- [ ] **Step 1: Worker logs its Platform.** In `kitchen-sink/src/worker.ts`, add `Platform` to the runtime import and log the three values right after the existing `console.log("started");`:

Change the import line `import { Events, Services, WindowEvent } from "@zappdev/runtime";` to:
```ts
import { Events, Platform, Services, WindowEvent } from "@zappdev/runtime";
```
Then after `console.log("started");` add:
```ts
// N2c smoke: Platform now works in worker code (os/formFactor/env carried from
// native via __zappBridge). Logs as `[zapp/greeter] platform: macos desktop dev`.
console.log(`platform: ${Platform.os} ${Platform.formFactor} ${Platform.env}`);
```
(`Services` may already be imported/used; keep it. If `tsc` flags `Services` or `WindowEvent` as unused, that is pre-existing — do not remove them as part of this task.)

- [ ] **Step 2: Docs — "In workers" note.** In `docs/api-reference.md`, find the Platform section and add a short subsection after the existing Platform content:

```markdown
#### Platform in workers

`Platform.os` / `isMacOS` / `isIOS` / `isWindows`, `Platform.formFactor` /
`isPhone` / `isTablet` / `isDesktop`, and `Platform.env` / `isDev` / `isProd`
all work in **worker** code too — the values are carried from native into each
worker (via the worker bridge) with the same API and meaning as in a webview.
`formFactor` in a worker is the device **idiom** (`"tablet"` on iPad, `"phone"`
on iPhone, `"desktop"` on macOS/Windows) — a worker has no window, so there is
no size-class notion.
```
(Match the surrounding heading depth — use `####` if the Platform section is `###`.)

- [ ] **Step 3: Full gates.** Run: `bun run check`; `bun test cli/src`; `bun run test:native`; `cd kitchen-sink && bun run build` (expect `[zapp] build complete:`); `cd kitchen-sink && bun run build --platform ios` (expect `[zapp] build complete:`).

- [ ] **Step 4: Commit.**
```bash
git add kitchen-sink/src/worker.ts docs/api-reference.md
git commit  # message below, with the required trailer
```
Message: `feat(kitchen-sink): worker logs Platform os/formFactor/env (N2c) + docs`

- [ ] **Step 5: macOS HUMAN SMOKE GATE.** STOP for the controller/user. Run the kitchen-sink on macOS (`cd kitchen-sink && bun run dev`). In the terminal log, the headless worker prints:
  ```
  [zapp/greeter] platform: macos desktop dev
  ```
  Verify: `os="macos"`, `formFactor="desktop"`, `env="dev"` (dev because `bun run dev`). A built/run app would print `... prod`. macOS build + iOS compile both green. (iOS device idiom path — `phone`/`tablet` — is verified by the iOS compile + code-equivalence with the prior webview logic, not an in-session sim smoke.)

## Self-Review

**Spec coverage:** §1 carrier shape → T1 Step 9 (worker.ts publish, full mirror). §2 sources → T1 Steps 3–8 (`zapp_form_factor()` darwin+ios, engines set permissions/env/formFactor, webview.m adopt). Zero platform.ts change → Step 10 doc-only. Test → Step 1. Demo+docs+smoke → T2. Engine parity (zjs+bare) → Steps 7+8. Single-source formFactor (webview.m adopts) → Steps 5+6. All spec sections covered.

**Placeholder scan:** every code step has concrete code; the two "mirror the exact local type/helper at line X" notes (engine string creation) are anchored to exact line numbers with the code shown — concrete, not placeholders.

**Type/name consistency:** prop names `permissions`/`env`/`formFactor` identical across zjs.c (Step 7), bare.c (Step 8), and worker.ts (Step 9). `zapp_form_factor()` signature identical in darwin def (Step 3), ios def (Step 4), and the three extern decls (Steps 5/6/7/8). The worker.ts default JSON string matches the engine fallback string. The published shape `{permissions, formFactor, env}` matches what `platform.ts` reads (os ← `permissions.platform`).
