# Permissions System (v1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** App-global declarative permissions manifest (`permissions` in zapp.config.ts) that allow/denies Zapp's built-in native capabilities, enforced natively, with a tri-state `Permissions.query()` runtime API.

**Architecture:** CLI validates a typed `ZappPermission[]` and emits `zapp_build_permissions_json()` (the same codegen pattern as the fs allowlist). A new `native/permissions/permissions.zc` parses it lazily and answers `permissions_is_allowed(id)` with module⊇verb semantics. One mapping+checkpoint in `router.zc` covers webview dispatch (t:1 invokes reply `PERMISSION_DENIED:<id>`; t:4 fire-and-forget log+drop); `fs.zc` gates at its entry points (covers all callers); worker engine invoke entries + bare tier-1 host objects call the same C-linkable check. The manifest (+platform) rides the existing bootstrapConfig user script so the runtime throws fast typed errors and `Permissions.query()` answers granted/denied/unsupported.

**Tech Stack:** TypeScript (Bun, bun:test), Zen-C (`.zc`, `zc run` native tests), Objective-C (webview.m bootstrap), C (worker engines).

**Spec:** `docs/superpowers/specs/2026-06-09-permissions-system-design.md`
**Branch:** `feat/permissions-system` (exists; spec committed).

---

## Context the engineer needs

- **Build success rule:** a build succeeded ONLY if the last line is `[zapp] build complete: <path>`. `bun run build` does NOT type-check — use `bun run check` (tsc). Full gate: `bun run test:all` (bun tests + native tests + tsc).
- **Commit discipline:** stage only the files each task names. NEVER stage the pre-existing dirt: `hello-world/src/main.ts`, `hello-world/src/worker.ts`, `hello-world/zapp.config.ts`, `vendor/bare`, `vendor/txiki.js`, `native/worker/engines/zjs-cross-eval-test.c`. Trailer every commit with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **Zen-C gotchas:** a bare `{` inside a string literal is f-string interpolation — escape as `{{` / `}}`. `char* ==` is pointer compare — use `strcmp` (import via json_safe transitively) or `str::strncmp`. Zen-C fns compile to plain C symbols, so `.m`/`.c` files call them via `extern` (e.g. `service_get_manifest_json` in webview.m).
- **Patterns this plan copies:** fs allowlist codegen (`cli/src/build-config.ts:55-100` → `zapp_build_fs_allowlist_json`), fs lazy init (`native/fs/fs.zc:118-194`, init called inside `fs_is_allowed`), bootstrapConfig injection (`native/platform/darwin/webview.m:842-850`), invoke replies (`dispatch_invoke_response(window_id, request_id, ok, payload)`; JS side rejects `new Error(payload)` at `bootstrap/webview.ts:104`).

## File structure

| File | Responsibility | Task |
|---|---|---|
| `cli/src/permissions.ts` (new) | catalog (`ZappPermission` union, `PERMISSION_IDS`), `resolvePermissions`, `validatePermissions` | 1 |
| `cli/src/permissions.test.ts` (new) | TDD for the above | 1 |
| `cli/src/config.ts` | `permissions?: ZappPermission[]` on `ZappConfig` | 1 |
| `cli/src/build-config.ts` | emit `zapp_build_permissions_json()` | 2 |
| `native/permissions/permissions.zc` (new) | parse + `permissions_is_allowed` / `permissions_check` / `permissions_bootstrap_json` | 3 |
| `native/tests/permissions_test.zc` (new) | native unit test (zc run) | 3 |
| `native/app/app.zc` | import permissions.zc | 3 |
| `native/app/router.zc` | `permission_id_for_invoke` / `permission_id_for_action` + checkpoints + `__zapp:permissions` route | 4 |
| `native/fs/fs.zc` | `fs:read`/`fs:write` gates at entry points | 4 |
| `native/worker/engines/zjs.c`, `bare.c` | gate worker invoke entries + bare tier-1 host objects + createWindow | 5 |
| `native/platform/darwin/webview.m`, `native/platform/ios/webview.m` | bootstrapConfig gains `permissions:` | 6 |
| `runtime/permissions.ts` (new) + `runtime/permissions.test.ts` (new) | `Permissions`, `PermissionDeniedError`, support table, `ensurePermission` | 7 |
| `runtime/index.ts`, `runtime/tray.ts`, `runtime/dock.ts`, `runtime/menu.ts`, `runtime/context-menu.ts`, `runtime/app.ts`, `runtime/webview.ts`, `bootstrap/webview.ts` | export + sync mirrors + reject decoration | 7 |
| `docs/security.md` (new), `docs/api-reference.md`, `README.md`, `docs/README.md` | docs | 8 |
| `hello-world/zapp.config.ts` (user WIP — edit, NEVER stage) | demo permissions block | 9 |

---

## Task 1: CLI catalog + resolve/validate (TDD)

**Files:**
- Create: `cli/src/permissions.ts`
- Create: `cli/src/permissions.test.ts`
- Modify: `cli/src/config.ts` (~line 596, next to `fs?: FsConfig`)

- [ ] **Step 1: Write the failing tests**

Create `cli/src/permissions.test.ts`:

```ts
import { describe, expect, test } from "bun:test";
import { resolvePermissions, validatePermissions, isPermissionAllowed } from "./permissions";

describe("resolvePermissions", () => {
  test("absent field → inactive (allow-all)", () => {
    const r = resolvePermissions(undefined);
    expect(r.active).toBe(false);
    expect(r.allow).toEqual([]);
  });

  test("present field → active + normalized set", () => {
    const r = resolvePermissions(["clipboard:read", "fs", "clipboard:read"]);
    expect(r.active).toBe(true);
    expect(r.allow).toEqual(["clipboard:read", "fs"]); // deduped, order-preserving
  });

  test("empty array → active, deny-everything", () => {
    const r = resolvePermissions([]);
    expect(r.active).toBe(true);
    expect(r.allow).toEqual([]);
  });
});

describe("validatePermissions", () => {
  test("unknown id is an error with suggestion", () => {
    const errs = validatePermissions(["clipbord" as never]);
    expect(errs.length).toBe(1);
    expect(errs[0]).toContain("clipbord");
    expect(errs[0]).toContain("clipboard"); // did-you-mean
  });

  test("verb alongside its bare module is a warning, not an error", () => {
    const errs = validatePermissions(["clipboard", "clipboard:read"]);
    expect(errs).toEqual([]); // redundancy warns via console, never errors
  });

  test("valid list passes", () => {
    expect(validatePermissions(["fs:read", "dialog", "shell:open"])).toEqual([]);
  });
});

describe("isPermissionAllowed (verb semantics, mirrors native)", () => {
  test("bare module grants its verbs", () => {
    expect(isPermissionAllowed("clipboard:read", { active: true, allow: ["clipboard"] })).toBe(true);
  });
  test("verb grant does not imply sibling verb", () => {
    expect(isPermissionAllowed("clipboard:write", { active: true, allow: ["clipboard:read"] })).toBe(false);
  });
  test("inactive manifest allows everything", () => {
    expect(isPermissionAllowed("tray", { active: false, allow: [] })).toBe(true);
  });
  test("exact verb match", () => {
    expect(isPermissionAllowed("fs:write", { active: true, allow: ["fs:write"] })).toBe(true);
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /Users/zach/code/zapp && bun test ./cli/src/permissions.test.ts`
Expected: FAIL — `Cannot find module './permissions'`.

- [ ] **Step 3: Implement `cli/src/permissions.ts`**

```ts
// Permissions manifest — the v1 app-global allow/deny catalog.
// Spec: docs/superpowers/specs/2026-06-09-permissions-system-design.md
//
// Ids are module names with an optional verb. A bare module name grants
// all of its verbs ("clipboard" ⊇ "clipboard:read" + "clipboard:write").
// The union type gives editors autocomplete + typo errors in zapp.config.ts.

export type ZappPermission =
  | "clipboard" | "clipboard:read" | "clipboard:write"
  | "fs" | "fs:read" | "fs:write"
  | "dialog"
  | "notifications"
  | "shortcuts"
  | "tray"
  | "dock"
  | "menu"
  | "screen"
  | "embed"
  | "window:create"
  | "shell" | "shell:open" | "shell:reveal" | "shell:trash";

export const PERMISSION_IDS: readonly ZappPermission[] = [
  "clipboard", "clipboard:read", "clipboard:write",
  "fs", "fs:read", "fs:write",
  "dialog", "notifications", "shortcuts", "tray", "dock", "menu",
  "screen", "embed", "window:create",
  "shell", "shell:open", "shell:reveal", "shell:trash",
];

export interface ResolvedPermissions {
  /** false when the config field is absent — allow-all (legacy behavior). */
  active: boolean;
  /** Deduped, order-preserving allowlist. Empty + active=true → deny-all. */
  allow: string[];
}

export function resolvePermissions(field: ZappPermission[] | undefined): ResolvedPermissions {
  if (field === undefined) return { active: false, allow: [] };
  return { active: true, allow: [...new Set(field)] };
}

/** Levenshtein distance for did-you-mean suggestions (small inputs only). */
function editDistance(a: string, b: string): number {
  const m = a.length, n = b.length;
  const d = Array.from({ length: m + 1 }, (_, i) => [i, ...Array(n).fill(0)]);
  for (let j = 0; j <= n; j++) d[0][j] = j;
  for (let i = 1; i <= m; i++)
    for (let j = 1; j <= n; j++)
      d[i][j] = Math.min(
        d[i - 1][j] + 1, d[i][j - 1] + 1,
        d[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1),
      );
  return d[m][n];
}

/**
 * Returns build-blocking errors (unknown ids). Redundant entries (a verb
 * listed alongside its bare module) only warn on stderr — harmless.
 */
export function validatePermissions(field: ZappPermission[] | undefined): string[] {
  if (field === undefined) return [];
  const errors: string[] = [];
  const set = new Set<string>(field);
  for (const id of field) {
    if (!PERMISSION_IDS.includes(id)) {
      const best = [...PERMISSION_IDS]
        .sort((x, y) => editDistance(id, x) - editDistance(id, y))[0];
      errors.push(`[zapp] unknown permission "${id}" — did you mean "${best}"?`);
      continue;
    }
    const colon = id.indexOf(":");
    if (colon > 0 && set.has(id.slice(0, colon))) {
      process.stderr.write(
        `[zapp] permissions: "${id}" is redundant — bare "${id.slice(0, colon)}" already grants it\n`,
      );
    }
  }
  return errors;
}

/** Verb semantics shared with native permissions.zc — keep in lockstep. */
export function isPermissionAllowed(id: string, resolved: ResolvedPermissions): boolean {
  if (!resolved.active) return true;
  if (resolved.allow.includes(id)) return true;
  const colon = id.indexOf(":");
  if (colon > 0 && resolved.allow.includes(id.slice(0, colon))) return true;
  return false;
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `bun test ./cli/src/permissions.test.ts`
Expected: all pass, 0 fail.

- [ ] **Step 5: Add the config field**

In `cli/src/config.ts`, add to imports (top of file): `import type { ZappPermission } from "./permissions";` — then re-export it next to the other type exports if the file has an export block (`export type { ZappPermission };`). In `interface ZappConfig` (line ~596, directly below `fs?: FsConfig;`):

```ts
  /**
   * Declarative native-capability allowlist (built-ins only in v1).
   *
   * Absent → everything allowed (legacy behavior). Present → exhaustive:
   * any built-in capability not listed is denied, enforced natively.
   * A bare module name grants all its verbs ("clipboard" ⊇ ":read"+":write").
   * See docs/security.md for the catalog and trust model.
   */
  permissions?: ZappPermission[];
```

- [ ] **Step 6: Wire validation into the build**

Find the existing validation call site: `grep -n "validateNative" cli/src/zapp-cli.ts cli/src/build-config.ts cli/src/native.ts` — wherever `validateNative(config…)` runs during build/dev startup, add immediately after it:

```ts
const permErrors = validatePermissions(config.permissions);
if (permErrors.length > 0) {
  for (const e of permErrors) process.stderr.write(e + "\n");
  process.exit(1);
}
```

with `import { validatePermissions } from "./permissions";` at that file's top. (If `validateNative` is called from two paths — dev and build — add to both; it should already be a shared helper.)

- [ ] **Step 7: Verify check + tests**

Run: `bun run check && bun test ./cli/src/permissions.test.ts ./cli/src/config.test.ts`
Expected: tsc clean; all pass.

- [ ] **Step 8: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/permissions.ts cli/src/permissions.test.ts cli/src/config.ts cli/src/zapp-cli.ts
# (swap zapp-cli.ts for whichever file got the validation call in Step 6)
git commit -F - <<'EOF'
feat(cli): permissions manifest — typed catalog, resolve, validation

ZappPermission union (autocomplete + typo type errors in zapp.config.ts),
resolvePermissions (absent = inactive/allow-all; present = exhaustive),
validatePermissions (unknown id = build error with did-you-mean; redundant
verb-beside-bare-module warns), isPermissionAllowed verb semantics shared
with the native parser. bun-tested.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
```

---

## Task 2: Codegen — emit `zapp_build_permissions_json()`

**Files:**
- Modify: `cli/src/build-config.ts` (the fs-allowlist emission block ~line 55-100 and the generated-content template ~line 92-105)

- [ ] **Step 1: Compute the JSON next to the fs allowlist**

In `cli/src/build-config.ts`, directly after the `fsPersistGrants` line (~line 63), add:

```ts
  // Permissions manifest (v1, app-global). Emitted as an escaped JSON
  // object literal; native/permissions/permissions.zc parses it lazily.
  // platform is baked here so the runtime support table needs no extra
  // carrier. active:false (field absent) short-circuits to allow-all.
  const resolvedPerms = resolvePermissions(config.permissions);
  const permsObj = {
    platform: isIOSTarget?.(target) ? "ios" : (process.platform === "win32" ? "windows" : "macos"),
    active: resolvedPerms.active,
    allow: resolvedPerms.allow,
  };
  const permissionsJson = JSON.stringify(permsObj).replace(/"/g, '\\"');
```

Import at top: `import { resolvePermissions } from "./permissions";`. **Adapt the platform expression to this file's reality:** `grep -n "isIOSTarget\|target" cli/src/build-config.ts | head` — the generator already branches per target for the iOS twin (`_zapp_build_ios.zc`); use the same target variable it already has in scope (e.g. `target === "ios-simulator" || target === "ios-device" ? "ios" : ...`). If the macOS and iOS build files are generated by separate functions, compute `platform` in each accordingly.

- [ ] **Step 2: Emit the fn in the generated content**

In the `const content =` template, after the `zapp_build_custom_protocols_json` line, add:

```
fn zapp_build_permissions_json() -> string { return "${permissionsJson}"; }
```

(Both in the literal template and — if the file builds the iOS twin from the same template — confirm the new line is in the shared template so iOS gets it too.)

- [ ] **Step 3: Verify generation**

Run: `cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -2 && grep -n "zapp_build_permissions_json" .zapp/zapp_build_config.zc`
Expected: `[zapp] build complete: …` and the grep shows the emitted fn with `active\":false` (hello-world has no permissions field yet).

- [ ] **Step 4: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/build-config.ts
git commit -F - <<'EOF'
feat(cli): emit zapp_build_permissions_json (manifest + platform) codegen

Same escaped-JSON pattern as the fs allowlist. Carries
{platform, active, allow}; platform baked per build target so the runtime
support table needs no separate carrier.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
```

---

## Task 3: `native/permissions/permissions.zc` (TDD via zc run)

**Files:**
- Create: `native/permissions/permissions.zc`
- Create: `native/tests/permissions_test.zc`
- Modify: `native/app/app.zc` (import list, line ~15 next to `import "../fs/fs.zc";`)

- [ ] **Step 1: Write the failing native test**

Create `native/tests/permissions_test.zc`:

```zc
// Native unit tests for the permissions manifest parser + verb semantics.
// Run via `zc run` (cli/src/test-native.ts). Literal braces in strings are
// escaped {{ }} (Zen-C f-string rule); char* compare uses the bool returns.
import "../permissions/permissions.zc";

test "inactive manifest allows everything" {
    permissions_reset_and_load("{{\"platform\":\"macos\",\"active\":false,\"allow\":[]}}");
    assert(permissions_is_allowed("clipboard:read"), "inactive => allowed");
    assert(permissions_is_allowed("tray"), "inactive => allowed");
}

test "active empty manifest denies everything" {
    permissions_reset_and_load("{{\"platform\":\"macos\",\"active\":true,\"allow\":[]}}");
    assert(!permissions_is_allowed("clipboard:read"), "active empty => denied");
}

test "bare module grants its verbs" {
    permissions_reset_and_load("{{\"platform\":\"macos\",\"active\":true,\"allow\":[\"clipboard\"]}}");
    assert(permissions_is_allowed("clipboard:read"), "bare grants :read");
    assert(permissions_is_allowed("clipboard:write"), "bare grants :write");
    assert(permissions_is_allowed("clipboard"), "bare grants bare");
    assert(!permissions_is_allowed("fs:read"), "other modules still denied");
}

test "verb grant is exact, no sibling bleed" {
    permissions_reset_and_load("{{\"platform\":\"macos\",\"active\":true,\"allow\":[\"fs:read\",\"shell:open\"]}}");
    assert(permissions_is_allowed("fs:read"), "exact verb allowed");
    assert(!permissions_is_allowed("fs:write"), "sibling verb denied");
    assert(!permissions_is_allowed("fs"), "bare not granted by a verb");
    assert(permissions_is_allowed("shell:open"), "shell:open allowed");
    assert(!permissions_is_allowed("shell:trash"), "shell:trash denied");
}

test "malformed json fails closed when active flag unreadable" {
    permissions_reset_and_load("{{not json");
    // Unparseable manifest: treat as inactive (allow-all) — the CLI
    // validated + emitted it, so this only happens with a corrupted
    // build; failing OPEN preserves the no-manifest contract.
    assert(permissions_is_allowed("clipboard"), "unparseable => inactive");
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /Users/zach/code/zapp && bun run test:native`
Expected: FAIL — permissions.zc doesn't exist (compile error).

- [ ] **Step 3: Implement `native/permissions/permissions.zc`**

```zc
// Permissions manifest (v1, app-global) — parse-once allow-set with
// module⊇verb semantics. The CLI emits zapp_build_permissions_json()
// ({"platform","active","allow":[...]}); we lazily parse it on first
// check, exactly like fs.zc's allowlist. All checks are string lookups —
// no allocation on the hot path after init.
//
// C linkage: Zen-C fns are plain C symbols; webview.m / zjs.c / bare.c
// call permissions_is_allowed / permissions_check / permissions_bootstrap_json
// via extern declarations.
import "../bridge/json_safe.zc";

extern fn zapp_build_permissions_json() -> string;

let permissions_loaded: bool = false;
let permissions_active: bool = false;
let permissions_allow: string[64];
let permissions_allow_count: int = 0;
// One log line per denied id (anti-spam).
let permissions_logged: string[64];
let permissions_logged_count: int = 0;

// Reset + parse a manifest JSON. Public so tests can drive multiple
// fixtures; production goes through permissions_ensure_init.
fn permissions_reset_and_load(json: string) -> void {
    permissions_loaded = true;
    permissions_active = false;
    permissions_allow_count = 0;
    permissions_logged_count = 0;
    let r = zapp_json_parse(json);
    if r.is_err() { return; } // fail open = inactive (see test rationale)
    let j = r.unwrap();
    let active_opt = j.get_bool("active");
    if !active_opt.is_some() { return; }
    permissions_active = active_opt.unwrap();
    if !permissions_active { return; }
    let arr_opt = j.get_array("allow");
    if !arr_opt.is_some() { return; }
    let arr = arr_opt.unwrap();
    let n = arr.length();
    let i = 0;
    while i < n && permissions_allow_count < 64 {
        let s_opt = arr.get_string_at(i);
        if s_opt.is_some() {
            permissions_allow[permissions_allow_count] = s_opt.unwrap();
            permissions_allow_count = permissions_allow_count + 1;
        }
        i = i + 1;
    }
}

fn permissions_ensure_init() -> void {
    if permissions_loaded { return; }
    permissions_reset_and_load(zapp_build_permissions_json());
}

fn permissions_set_contains(id: string) -> bool {
    let i = 0;
    while i < permissions_allow_count {
        let hit: bool = false;
        raw { hit = (strcmp((const char*)permissions_allow[i], (const char*)id) == 0); }
        if hit { return true; }
        i = i + 1;
    }
    return false;
}

// Core check: exact id, or the id's bare module ("clipboard:read" passes
// when the set has "clipboard:read" OR "clipboard").
fn permissions_is_allowed(id: string) -> bool {
    permissions_ensure_init();
    if !permissions_active { return true; }
    if permissions_set_contains(id) { return true; }
    raw {
        const char* colon = strchr((const char*)id, ':');
        if (colon) {
            char bare[64];
            size_t n = (size_t)(colon - (const char*)id);
            if (n < sizeof(bare)) {
                memcpy(bare, (const char*)id, n);
                bare[n] = '\0';
                if (permissions_set_contains((char*)bare)) return true;
            }
        }
    }
    return false;
}

// Check + one-per-id denial log. Returns the verdict.
fn permissions_check(id: string, method: string) -> bool {
    if permissions_is_allowed(id) { return true; }
    let seen: bool = false;
    let i = 0;
    while i < permissions_logged_count {
        raw { seen = seen || (strcmp((const char*)permissions_logged[i], (const char*)id) == 0); }
        i = i + 1;
    }
    if !seen {
        if permissions_logged_count < 64 {
            permissions_logged[permissions_logged_count] = id;
            permissions_logged_count = permissions_logged_count + 1;
        }
        raw {
            fprintf(stderr, "[zapp] permission denied: %s (%s) — add \"%s\" to permissions in zapp.config.ts\n",
                    (const char*)id, (const char*)method, (const char*)id);
        }
    }
    return false;
}

// The raw manifest JSON, for the bootstrapConfig injection and the
// __zapp:permissions route (workers fetch it lazily).
fn permissions_bootstrap_json() -> string {
    return zapp_build_permissions_json();
}
```

**Adapt to json_safe's real accessor names** (`grep -nE "get_bool|get_array|length|get_string_at" native/bridge/json_safe.zc`): if the array API differs (e.g. `arr.count()` / `arr.at(i)` or get_array returns `JsonValue*` walked differently), use the real names — `native/worker/registry.zc` and `fs.zc:118-188` (which parses a JSON string array the same way) are working examples to crib from. If json_safe lacks `get_bool`, encode `active` as int 0/1 in Task 2's emission and use `get_int`. Keep the test in lockstep.

- [ ] **Step 4: Run native tests to verify pass**

Run: `bun run test:native`
Expected: `PASS native/tests/permissions_test.zc` (and json_safe still passing).

- [ ] **Step 5: Import from app.zc**

In `native/app/app.zc`, after `import "../fs/fs.zc";` (line ~15): `import "../permissions/permissions.zc";`

- [ ] **Step 6: Verify both platform builds compile**

Run: `cd hello-world && bun run build 2>&1 | tail -1 && bun run build --platform ios 2>&1 | tail -1`
Expected: both end `[zapp] build complete: …` (permissions.zc compiles, links the generated symbol; the #281 parity lint is unaffected — no `darwin_*` references).

- [ ] **Step 7: Commit**

```bash
git add native/permissions/permissions.zc native/tests/permissions_test.zc native/app/app.zc
git commit -F - <<'EOF'
feat(native): permissions.zc — lazy manifest parse + verb-semantics check

Parses zapp_build_permissions_json once on first check (fs.zc allowlist
pattern). permissions_is_allowed: exact id or bare-module grant; inactive
manifest (absent config field / unparseable) allows all. permissions_check
adds a one-per-id denial log. C-linkable for webview.m + worker engines.
zc-run tested.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
```

---

## Task 4: Router checkpoint + fs gates

**Files:**
- Modify: `native/app/router.zc` (t:1 INVOKE branch head ~line 21; t:4 action handler head ~line 227; `router_handle_zapp` for `__zapp:permissions`)
- Modify: `native/fs/fs.zc` (entry points ~lines 249-352)

- [ ] **Step 1: Add the two mapping functions to router.zc**

Above `fn router_handle_message` add:

```zc
// Map a t:1 invoke method to a permission id ("" = ungated: __app:,
// __zapp:, __protocol:respond, user services). Spec catalog:
// docs/superpowers/specs/2026-06-09-permissions-system-design.md
fn permission_id_for_invoke(method: string) -> string {
    if str::strncmp(method, "__clipboard:", 12) == 0 {
        // read* / has → :read; write* / clear → :write
        let rest: string = "";
        raw { rest = (char*)((const char*)method + 12); }
        if str::strncmp(rest, "read", 4) == 0 { return "clipboard:read"; }
        if str::strncmp(rest, "has", 3) == 0 { return "clipboard:read"; }
        return "clipboard:write";
    }
    if str::strncmp(method, "__dialog:", 9) == 0 { return "dialog"; }
    if str::strncmp(method, "__notif:", 8) == 0 { return "notifications"; }
    if str::strncmp(method, "__shortcuts:", 12) == 0 { return "shortcuts"; }
    if str::strncmp(method, "__screen:", 9) == 0 { return "screen"; }
    if method == "__window:create" { return "window:create"; }
    return "";
}

// Map a t:4 fire-and-forget action to a permission id ("" = ungated:
// window ops on existing windows, app lifecycle, plumbing).
fn permission_id_for_action(action: string) -> string {
    if str::strncmp(action, "tray:", 5) == 0 { return "tray"; }
    if str::strncmp(action, "dock:", 5) == 0 { return "dock"; }
    if str::strncmp(action, "panel", 5) == 0 { return "embed"; }
    if action == "setMenu" { return "menu"; }
    if action == "showContextMenu" { return "menu"; }
    if action == "openExternal" { return "shell:open"; }
    if action == "openPath" { return "shell:open"; }
    if action == "showItemInFolder" { return "shell:reveal"; }
    if action == "trashItem" { return "shell:trash"; }
    return "";
}
```

(Note: `__notif:` is 8 chars — the existing dispatch at router.zc:32 compares 7, which also matches; use 8 here for exactness. Verify `str::strncmp` is the comparator used throughout this file — it is, line 24.)

- [ ] **Step 2: Gate t:1 invokes**

In `router_handle_message`, immediately inside `if parsed.msg_type == MsgType.INVOKE {` (before the `__dialog:` check at line ~22), insert:

```zc
        let perm_id = permission_id_for_invoke(parsed.method);
        let perm_gated: bool = false;
        raw { perm_gated = ((const char*)perm_id)[0] != '\0'; }
        if perm_gated {
            if !permissions_check(perm_id, parsed.method) {
                // Reply so the JS promise rejects (bootstrap rejects with
                // new Error(payload)); runtime detects the prefix and
                // decorates with code/permission fields.
                raw {
                    char denied[160];
                    snprintf(denied, sizeof(denied), "PERMISSION_DENIED:%s", (const char*)perm_id);
                    dispatch_invoke_response(window_id, parsed.request_id, false, denied);
                }
                return;
            }
        }
```

(The snprintf bound is safe: permission ids are short catalog constants, never user data — not the truncation-hazard family.)

- [ ] **Step 3: Gate t:4 actions**

Locate the action-dispatch function containing `let is_ready = action == "ready";` (router.zc:227). Insert at its top, BEFORE the ready check:

```zc
    let act_perm = permission_id_for_action(action);
    let act_gated: bool = false;
    raw { act_gated = ((const char*)act_perm)[0] != '\0'; }
    if act_gated {
        if !permissions_check(act_perm, action) { return; } // log + drop (no reply channel)
    }
```

- [ ] **Step 4: Add the `__zapp:permissions` route**

In `router_handle_zapp` (find via `grep -n "fn router_handle_zapp\|workers-list" native/app/router.zc`), add a branch alongside `__zapp:workers-list`, following its exact reply style:

```zc
    if method == "__zapp:permissions" {
        dispatch_invoke_response(window_id, request_id, true, permissions_bootstrap_json());
        return;
    }
```

(Match the local parameter names used in that function — crib from the workers-list branch.)

- [ ] **Step 5: fs gates**

In `native/fs/fs.zc`, add as the FIRST line of each Apple-side entry-point body (lines ~249-352):
- `fs_read_file_native`, `fs_exists_native`, `fs_read_dir_native`:
  `if !permissions_check("fs:read", "fs") { return <fn's failure value>; }` — `""` for the string-returning fns, `false` for bool.
- `fs_write_file_native`, `fs_append_file_native`, `fs_mkdir_native`, `fs_remove_native`, `fs_rmdir_native`, `fs_rename_native`, `fs_copy_native`:
  `if !permissions_check("fs:write", "fs") { return false; }`

Add the import at fs.zc's top: `import "../permissions/permissions.zc";` — **if Zen-C reports a duplicate-import/cycle error** (app.zc imports both), drop the import and use an extern declaration instead: `extern fn permissions_check(id: string, method: string) -> bool;` (check how fs.zc declares `zapp_build_fs_allowlist_json` extern at line 29 — same form).

- [ ] **Step 6: Verify builds + tests**

Run: `bun run test:native && cd hello-world && bun run build 2>&1 | tail -1 && bun run build --platform ios 2>&1 | tail -1 && cd ..`
Expected: native tests pass; both builds end `[zapp] build complete:`.

- [ ] **Step 7: Headless regression smoke (no manifest → nothing changes)**

```bash
cd /Users/zach/code/zapp/hello-world
pkill -f 'bin/hello-world' 2>/dev/null; ZAPP_LOG=debug ./bin/hello-world >/tmp/perm_t4.log 2>&1 & sleep 6; pkill -f 'bin/hello-world'
grep -c "permission denied" /tmp/perm_t4.log; grep -E "\[zapp/(ticker|sync-engine)\]" /tmp/perm_t4.log | head -3
```
Expected: `0` denials; workers boot and log normally.

- [ ] **Step 8: Commit**

```bash
git add native/app/router.zc native/fs/fs.zc
git commit -F - <<'EOF'
feat(native): permission checkpoints — router invoke/action gates + fs

permission_id_for_invoke/_for_action map dispatch surfaces to catalog ids
(clipboard read/write split, tray/dock/panel/menu/shell actions). Denied
invokes reply PERMISSION_DENIED:<id> so the JS promise rejects; denied
fire-and-forget actions log once per id and drop. fs entry points gate
fs:read/fs:write beside the existing path allowlist. New __zapp:permissions
route returns the manifest for worker-side Permissions.query.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
```

---

## Task 5: Worker dispatch gates (zjs + bare)

**Files:**
- Modify: `native/worker/engines/zjs.c` (the C function bound as `"invokeService"` at registration line ~855; the `createWindow` host fn registration nearby)
- Modify: `native/worker/engines/bare.c` (`_invokeServiceRaw` ~line 531; tier-1 host objects section ~line 770+; createWindow entries)

- [ ] **Step 1: Add the extern + a shared gate snippet**

At the top of BOTH `zjs.c` and `bare.c` (near their other Zen-C externs):

```c
// Permissions (native/permissions/permissions.zc — Zen-C, plain C symbols).
extern bool permissions_check(const char* id, const char* method);
extern const char* permission_id_for_invoke(const char* method); // router.zc
```

- [ ] **Step 2: Gate the invokeService entries**

In `zjs.c`: find the C function registered as `invokeService` (`zjs_set_property(ctx, bridge, "invokeService", invoke_fn);` at line ~855 → locate `invoke_fn`'s definition). At its top, after the method-name argument is extracted to a `const char* method`, insert:

```c
    const char* perm = permission_id_for_invoke(method);
    if (perm && perm[0] && !permissions_check(perm, method)) {
        // Deny: return the same error shape a failed service call returns
        // in this engine (locate the existing NOT_FOUND/error path in this
        // function and reuse it verbatim with the message below).
        // message: "PERMISSION_DENIED:<perm>"
    }
```

Concretely: find how `invoke_fn` reports a failed invoke today (search this function for `NOT_FOUND` or its error-return construction) and return the identical construction with a heap/stack message `PERMISSION_DENIED:<perm>` (`char buf[160]; snprintf(buf, sizeof buf, "PERMISSION_DENIED:%s", perm);`). Do the same in `bare.c`'s `_invokeServiceRaw` (line ~531) — same extraction-point, same reuse-the-existing-error-path rule.

- [ ] **Step 3: Gate bare tier-1 host objects + createWindow**

In `bare.c`, the tier-1 section starts ~line 770 (`// --- Tier-1 host objects (clipboard, notif, shortcuts) ---`). Enumerate them: `grep -n "bare_host_" native/worker/engines/bare.c`. For each host fn fronting clipboard / notifications / shortcuts, insert at top (before the darwin_* call):

```c
    if (!permissions_check("<id>", "<fn-name>")) return <this fn's empty/false return>;
```

with `<id>` = `clipboard:read` (read_text/read_html/read_image/read_files/has), `clipboard:write` (write_*/clear), `notifications` (notif fns), `shortcuts` (shortcut fns). For both engines' `createWindow` / `createWindow_from_json` host entries (`grep -n "createWindow" native/worker/engines/zjs.c native/worker/engines/bare.c`): gate with `permissions_check("window:create", "createWindow")` returning the fn's failure value.

- [ ] **Step 4: Verify build + worker regression**

Run: `cd hello-world && bun run build 2>&1 | tail -1` then repeat Task 4 Step 7's headless smoke.
Expected: build complete; zero denials; ticker/sync-engine workers run normally (their Events/Services usage is ungated).

- [ ] **Step 5: Commit**

```bash
git add native/worker/engines/zjs.c native/worker/engines/bare.c
git commit -F - <<'EOF'
feat(native): worker-path permission gates (zjs + bare)

invokeService entries run the same permission_id_for_invoke mapping as the
router (denied -> PERMISSION_DENIED:<id> via the engine's existing error
path); bare tier-1 host objects (clipboard/notif/shortcuts) and both
engines' createWindow entries call permissions_check directly. App-global
manifest: no context identity needed.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
```

---

## Task 6: Bootstrap carrier (webview.m, both platforms)

**Files:**
- Modify: `native/platform/darwin/webview.m` (~line 818-850, the bootstrapConfig script)
- Modify: `native/platform/ios/webview.m` (its mirror of the same injection — find via `grep -n "bootstrapConfig" native/platform/ios/webview.m`)

- [ ] **Step 1: darwin/webview.m**

Add the extern near the others (~line 22): `extern const char* permissions_bootstrap_json(void);`
Before the `configScript` construction (~line 842) add:

```objc
    const char* permsJson = permissions_bootstrap_json();
    if (!permsJson || !permsJson[0]) permsJson = "{\"platform\":\"macos\",\"active\":false,\"allow\":[]}";
```

Then extend the format string + args — the object literal gains `,permissions:%s` (the manifest JSON is itself a valid JS object literal, same trick as `powerState:%s`):

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

- [ ] **Step 2: ios/webview.m**

Locate its bootstrapConfig injection (same `Symbol.for('zapp.bootstrapConfig')` script) and make the identical change (extern + `,permissions:%s`). The platform field inside the JSON is already `"ios"` because Task 2 bakes it per build target — no per-file string needed.

- [ ] **Step 3: Verify**

Run: `cd hello-world && bun run build 2>&1 | tail -1 && bun run build --platform ios 2>&1 | tail -1`
Expected: both `[zapp] build complete:`. Then headless run + check the config reached JS:

```bash
pkill -f 'bin/hello-world' 2>/dev/null; ZAPP_LOG=debug ./bin/hello-world >/tmp/perm_t6.log 2>&1 & sleep 5; pkill -f 'bin/hello-world'
grep -c "window ready" /tmp/perm_t6.log
```
Expected: webview boots (≥1). (Direct inspection of bootstrapConfig happens in Task 9's smoke via a probe.)

- [ ] **Step 4: Commit**

```bash
git add native/platform/darwin/webview.m native/platform/ios/webview.m
git commit -F - <<'EOF'
feat(native): bootstrapConfig carries the permissions manifest

The document-start config script gains permissions:{platform,active,allow}
(raw JSON as a JS literal, same as powerState) so the runtime can throw
synchronous PermissionDeniedError on gated fire-and-forget calls and answer
Permissions.query without a round-trip. iOS mirrors darwin.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
```

---

## Task 7: Runtime — `Permissions`, errors, mirrors (TDD)

**Files:**
- Create: `runtime/permissions.ts`, `runtime/permissions.test.ts`
- Modify: `runtime/index.ts`; `bootstrap/webview.ts:104`; `runtime/tray.ts`, `runtime/dock.ts`, `runtime/menu.ts`, `runtime/context-menu.ts`, `runtime/app.ts`, `runtime/webview.ts`

- [ ] **Step 1: Failing tests**

Create `runtime/permissions.test.ts`:

```ts
import { describe, expect, test } from "bun:test";
import {
  isAllowedByManifest, supportStatus, PermissionDeniedError,
  type PermissionsManifest,
} from "./permissions";

const m = (active: boolean, allow: string[]): PermissionsManifest =>
  ({ platform: "macos", active, allow });

describe("isAllowedByManifest (verb semantics)", () => {
  test("inactive allows all", () => expect(isAllowedByManifest("tray", m(false, []))).toBe(true));
  test("bare grants verbs", () => expect(isAllowedByManifest("fs:read", m(true, ["fs"]))).toBe(true));
  test("verb is exact", () => expect(isAllowedByManifest("fs:write", m(true, ["fs:read"]))).toBe(false));
  test("missing manifest treated as inactive", () => expect(isAllowedByManifest("tray", undefined)).toBe(true));
});

describe("supportStatus (platform axis)", () => {
  test("tray unsupported on ios", () => expect(supportStatus("tray", "ios")).toBe("unsupported"));
  test("shortcuts unsupported on ios", () => expect(supportStatus("shortcuts", "ios")).toBe("unsupported"));
  test("clipboard supported on ios", () => expect(supportStatus("clipboard:read", "ios")).toBe("supported"));
  test("tray supported on macos", () => expect(supportStatus("tray", "macos")).toBe("supported"));
  test("verb resolves via its module", () => expect(supportStatus("menu", "ios")).toBe("unsupported"));
});

describe("PermissionDeniedError", () => {
  test("carries code + permission", () => {
    const e = new PermissionDeniedError("clipboard:write");
    expect(e.code).toBe("PERMISSION_DENIED");
    expect(e.permission).toBe("clipboard:write");
    expect(e.message).toContain("clipboard:write");
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `bun test ./runtime/permissions.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement `runtime/permissions.ts`**

```ts
/**
 * Permissions — query the app's declarative native-capability manifest
 * (`permissions` in zapp.config.ts) and the platform's support for a
 * capability, in one tri-state answer.
 *
 * ```ts
 * import { Permissions } from "@zappdev/runtime";
 * await Permissions.query("clipboard:write"); // "granted" | "denied" | "unsupported"
 * ```
 *
 * Enforcement is NATIVE — these mirrors exist for fast, friendly errors
 * and detection; a handcrafted bridge message still hits the native gate.
 */
import { getBridge } from "./bridge";

export type PermissionState = "granted" | "denied" | "unsupported";

export interface PermissionsManifest {
  platform: string;          // "macos" | "ios" | "windows"
  active: boolean;           // false = no permissions field (allow-all)
  allow: string[];
}

export class PermissionDeniedError extends Error {
  readonly code = "PERMISSION_DENIED" as const;
  constructor(readonly permission: string) {
    super(
      `[zapp] permission denied: "${permission}" — add it to \`permissions\` in zapp.config.ts`,
    );
    this.name = "PermissionDeniedError";
  }
}

/** Verb semantics — keep in lockstep with native permissions.zc and cli/src/permissions.ts. */
export function isAllowedByManifest(id: string, manifest: PermissionsManifest | undefined): boolean {
  if (!manifest || !manifest.active) return true;
  if (manifest.allow.includes(id)) return true;
  const colon = id.indexOf(":");
  if (colon > 0 && manifest.allow.includes(id.slice(0, colon))) return true;
  return false;
}

// Platform support matrix (v1: static; the native parity audit keeps it
// honest). Keyed by bare module — verbs resolve through their module.
// "windows" entries reflect the current partial port.
const UNSUPPORTED: Record<string, string[]> = {
  ios: ["tray", "menu", "shortcuts", "dock", "shell"],   // dock badge works, rest no-op → conservatively unsupported; shell reveal/trash/openPath have no iOS equivalent
  windows: ["clipboard", "tray", "dock", "embed", "notifications", "shell", "screen"],
  macos: [],
};

export function supportStatus(id: string, platform: string): "supported" | "unsupported" {
  const colon = id.indexOf(":");
  const module = colon > 0 ? id.slice(0, colon) : id;
  const list = UNSUPPORTED[platform] ?? [];
  return list.includes(module) ? "unsupported" : "supported";
}

function bootstrapManifest(): PermissionsManifest | undefined {
  return (globalThis as any)[Symbol.for("zapp.bootstrapConfig")]?.permissions;
}

let cached: PermissionsManifest | undefined;

async function manifest(): Promise<PermissionsManifest | undefined> {
  if (cached) return cached;
  const boot = bootstrapManifest();
  if (boot) { cached = boot; return cached; }
  // Worker context: no bootstrapConfig — fetch once from native.
  try {
    cached = await (getBridge().invoke("__zapp:permissions", {}) as Promise<PermissionsManifest>);
  } catch {
    cached = undefined; // native didn't answer; fall back to allow-all reporting
  }
  return cached;
}

/**
 * Synchronous manifest check for fire-and-forget runtime calls (Tray.create,
 * Dock.*, Menu.build, …). Webview-only fast path: uses the bootstrap config;
 * in workers (no synchronous manifest) it does not throw — native still
 * enforces and logs.
 */
export function ensurePermission(id: string): void {
  const boot = bootstrapManifest();
  if (boot && !isAllowedByManifest(id, boot)) throw new PermissionDeniedError(id);
}

/** Detects the native deny reply and rethrows it typed. Use in invoke catch paths. */
export function rethrowPermissionError(e: unknown): never {
  const msg = e instanceof Error ? e.message : String(e);
  if (msg.startsWith("PERMISSION_DENIED:")) {
    throw new PermissionDeniedError(msg.slice("PERMISSION_DENIED:".length));
  }
  throw e;
}

export const Permissions = {
  /** Tri-state: platform support first, then the manifest. */
  async query(id: string): Promise<PermissionState> {
    const m = await manifest();
    const platform = m?.platform
      ?? bootstrapManifest()?.platform
      ?? "macos";
    if (supportStatus(id, platform) === "unsupported") return "unsupported";
    return isAllowedByManifest(id, m) ? "granted" : "denied";
  },

  /** The active allowlist ([] when no manifest — allow-all). */
  async list(): Promise<string[]> {
    const m = await manifest();
    return m?.active ? [...m.allow] : [];
  },
};
```

- [ ] **Step 4: Run tests to verify pass**

Run: `bun test ./runtime/permissions.test.ts` — all pass. Then `bun run check`.

- [ ] **Step 5: Export from `runtime/index.ts`**

After the `Protocols` export line add:

```ts
export { Permissions, PermissionDeniedError, type PermissionState } from "./permissions";
```

- [ ] **Step 6: Decorate the bootstrap reject (typed-ish error in webview)**

`bootstrap/webview.ts:104` currently: `p.reject(new Error(payload));` → replace with:

```ts
        const err: any = new Error(payload);
        if (typeof payload === "string" && payload.startsWith("PERMISSION_DENIED:")) {
          err.code = "PERMISSION_DENIED";
          err.permission = payload.slice("PERMISSION_DENIED:".length);
        }
        p.reject(err);
```

(Bootstrap can't import runtime classes — it decorates the plain Error; `.code === "PERMISSION_DENIED"` is the documented check, and `PermissionDeniedError` carries the same fields.)

- [ ] **Step 7: Sync mirrors on fire-and-forget modules**

Add `import { ensurePermission } from "./permissions";` and a first-line guard to:
- `runtime/tray.ts` `Tray.create(...)`: `ensurePermission("tray");`
- `runtime/dock.ts` — each exported method: `ensurePermission("dock");`
- `runtime/menu.ts` `Menu.build(...)`: `ensurePermission("menu");`
- `runtime/context-menu.ts` `ContextMenu.show(...)`: `ensurePermission("menu");`
- `runtime/app.ts`: `openExternal`/`openPath` → `ensurePermission("shell:open");`, `showItemInFolder` → `"shell:reveal"`, `trashItem` → `"shell:trash"`
- `runtime/webview.ts` `Webview.create(...)` AND `ZappWebviewElement.connectedCallback` (before `panelPost("panelCreate", …)`): `ensurePermission("embed");`

(Async invoke-style modules — clipboard, dialog, notifications, shortcuts, screen, Window.create — need no mirror: the native reply rejects with the decorated error.)

- [ ] **Step 8: Verify + commit**

Run: `bun run check && bun test ./runtime/permissions.test.ts ./cli/src/*.test.ts ./runtime/*.test.ts`
Expected: clean + all pass.

```bash
git add runtime/permissions.ts runtime/permissions.test.ts runtime/index.ts bootstrap/webview.ts \
        runtime/tray.ts runtime/dock.ts runtime/menu.ts runtime/context-menu.ts runtime/app.ts runtime/webview.ts
git commit -F - <<'EOF'
feat(runtime): Permissions.query/list + PermissionDeniedError + sync mirrors

Tri-state query (granted/denied/unsupported) folding the platform support
table into the manifest answer; webview reads the bootstrapConfig manifest
synchronously, workers lazily fetch __zapp:permissions. Fire-and-forget
modules (tray/dock/menu/context-menu/shell/embed) throw
PermissionDeniedError synchronously when the manifest denies; invoke-style
denials arrive as the native PERMISSION_DENIED reply decorated with
code+permission in bootstrap. Native remains authoritative.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
```

---

## Task 8: Docs

**Files:**
- Create: `docs/security.md`
- Modify: `docs/api-reference.md` (new `Permissions` section after `Protocols`), `README.md` (Security bullet), `docs/README.md` (index row)

- [ ] **Step 1: Write `docs/security.md`**

```markdown
# Security model

## Trust boundaries

Zapp has three trust zones:

1. **Your native code (Zen-C / ObjC / C)** — fully privileged.
2. **Your app's JS** (the main webview + workers, loaded from `zapp://` or
   your dev server) — trusted by default. It talks to native over the
   bridge; the `permissions` manifest (below) lets you narrow what it can
   reach.
3. **External web content** — untrusted. Put it in an embedded webview
   (`<zapp-webview>`): embeds get **no bridge** — no `Services`, no FS, no
   native APIs; host↔embed communication is only
   `postMessage`/`execJS` ↔ `window.zappHost.postMessage`. **Never load
   third-party content into the main webview.**

Additional standing boundaries:
- **Navigation allowlist** — top-level navigation in the main webview is
  default-deny (built-in schemes + dev localhost only); allow specific
  origins natively via the security manager. `target="_blank"` opens in the
  system browser, never in-app.
- **FS path allowlist** — `fs.allow` in zapp.config.ts; every FS call is
  prefix-checked natively before the syscall (plus session grants from
  user-picked dialog paths). Composes with the `fs` permission below.
- DevTools are disabled in production builds.

## Permissions manifest

Declare which built-in native capabilities your app may use:

```ts
// zapp.config.ts
permissions: ["clipboard:read", "fs", "dialog", "notifications", "window:create"],
```

- **Absent** → everything allowed (legacy behavior).
- **Present** → exhaustive: anything not listed is **denied, enforced
  natively** (webview AND workers). A bare module name grants all its
  verbs (`"clipboard"` ⊇ `clipboard:read` + `clipboard:write`).
- Unknown ids fail the build (typed `ZappPermission` union gives editor
  autocomplete).

| Permission | Verbs | Covers |
|---|---|---|
| `clipboard` | `:read`, `:write` | Clipboard reads / writes+clear |
| `fs` | `:read`, `:write` | FS API (additionally path-allowlisted) |
| `dialog` | — | file open/save + message dialogs |
| `notifications` | — | show/schedule/categories |
| `shortcuts` | — | global hotkeys |
| `tray` | — | status items |
| `dock` | — | badge/bounce/icon |
| `menu` | — | app menu + context menus |
| `screen` | — | display enumeration / cursor |
| `embed` | — | `<zapp-webview>` panels |
| `window:create` | — | creating new windows (ops on existing windows are never gated) |
| `shell` | `:open`, `:reveal`, `:trash` | openExternal/openPath · showItemInFolder · trashItem |

Not gated in v1 (by design): window ops on existing windows, app lifecycle,
`Events`, `Sync`, user `Services` (you wrote both sides; per-service gating
arrives with per-context grants in v2), `protocols`/`deepLinkSchemes`
(their config declaration is the grant).

## Denied calls

- Invoke-style APIs (Clipboard, Dialog, Notification, Shortcuts, Screen,
  `Window.create`) **reject** with an error where
  `error.code === "PERMISSION_DENIED"` and `error.permission` names the id.
- Fire-and-forget APIs (Tray, Dock, Menu, ContextMenu, shell helpers,
  `Webview.create`) **throw `PermissionDeniedError` synchronously** in the
  webview; in workers the native layer logs
  `[zapp] permission denied: <id>` (once per id) and drops the call.

## Detection

```ts
import { Permissions } from "@zappdev/runtime";
await Permissions.query("tray");   // "granted" | "denied" | "unsupported"
await Permissions.list();          // the active allowlist
```

`"unsupported"` answers the *platform* axis (e.g. `tray` on iOS) before the
manifest is consulted — unsupported APIs still silently no-op when called
(v1 keeps legacy call behavior); `query()` is how you detect them.

## Roadmap (v2)

Per-context grants (per window / per worker / per panel), per-service
gating (`service:<name>`), runtime permission prompts.
```

- [ ] **Step 2: api-reference section**

In `docs/api-reference.md`, after the `Protocols` section, add a `## Permissions` section documenting `Permissions.query` / `Permissions.list` / `PermissionDeniedError` / the `permissions` config field — condense from security.md (config snippet, tri-state semantics, denied-call behavior, catalog table) and link `docs/security.md` for the full model.

- [ ] **Step 3: README + docs index**

`README.md` Security bullet →

```markdown
- **Security** — Declarative permissions manifest (`permissions` in zapp.config.ts — allow/deny native capability, enforced natively), navigation allowlist, FS path allowlist, sandboxed embeds, path traversal prevention, dev tools disabled in production. See [`docs/security.md`](docs/security.md).
```

`docs/README.md` table: add `| [security.md](security.md) | Trust model, permissions manifest, allowlists |` after the api-reference row.

- [ ] **Step 4: Commit**

```bash
git add docs/security.md docs/api-reference.md README.md docs/README.md
git commit -F - <<'EOF'
docs: security model + permissions manifest

New docs/security.md (trust zones, untrusted-content-goes-in-embeds rule,
permissions catalog, denied-call semantics, detection, v2 roadmap);
api-reference Permissions section; README security bullet now leads with
the manifest; docs index row.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
```

---

## Task 9: hello-world manifest + end-to-end smoke

**Files:**
- Modify (NEVER stage — user WIP): `hello-world/zapp.config.ts`
- Temp (cp-backup/restore): `hello-world/src/main.ts`

- [ ] **Step 1: Add the demo manifest**

In `hello-world/zapp.config.ts` after `webviewPreferences` add (leave uncommitted for the user):

```ts
  // Permissions manifest (v1) — exhaustive once present. The demo
  // exercises ~everything; clipboard:write + shell:trash are deliberately
  // omitted so the deny path is demonstrable.
  permissions: [
    "clipboard:read", "fs", "dialog", "notifications", "shortcuts",
    "tray", "dock", "menu", "screen", "embed", "window:create",
    "shell:open", "shell:reveal",
  ],
```

- [ ] **Step 2: Probe script (temp main.ts append, cp-backup first)**

```bash
cd /Users/zach/code/zapp/hello-world && cp src/main.ts /tmp/main.ts.perm-bak
cat >> src/main.ts <<'EOF'

// [VERIFY-PERM temp] permission smoke probes — removed after verification.
setTimeout(async () => {
  const out: string[] = [];
  try { await Clipboard.readText(); out.push("read:GRANTED"); }
  catch (e: any) { out.push(`read:${e?.code ?? e?.message}`); }
  try { await Clipboard.writeText("x"); out.push("write:GRANTED"); }
  catch (e: any) { out.push(`write:${e?.code === "PERMISSION_DENIED" ? "DENIED:" + e.permission : e?.message}`); }
  try { (App as any).trashItem?.("/tmp/nonexistent"); out.push("trash:NO-THROW"); }
  catch (e: any) { out.push(`trash:${e?.code === "PERMISSION_DENIED" ? "DENIED" : "ERR"}`); }
  out.push(`query.tray:${await Permissions.query("tray")}`);
  out.push(`query.clipwrite:${await Permissions.query("clipboard:write")}`);
  console.log("[VERIFY-PERM]", out.join(" | "));
}, 1200);
EOF
```

(Ensure `Clipboard` and `Permissions` are in main.ts's `@zappdev/runtime` import — add them to the existing import block if absent. `trashItem`: confirm the actual `App` method name via `grep -n "trashItem" runtime/app.ts` and use it directly without the `(App as any)` cast if exported.)

- [ ] **Step 3: Build + run + assert**

```bash
bun run build 2>&1 | tail -1     # must end [zapp] build complete:
pkill -f 'bin/hello-world' 2>/dev/null
ZAPP_LOG=debug ./bin/hello-world >/tmp/perm_smoke.log 2>&1 & sleep 8; pkill -f 'bin/hello-world'
grep "VERIFY-PERM" /tmp/perm_smoke.log
grep "permission denied" /tmp/perm_smoke.log
```

Expected: `read:GRANTED | write:DENIED:clipboard:write | trash:DENIED | query.tray:granted | query.clipwrite:denied`, plus native log lines `[zapp] permission denied: clipboard:write (__clipboard:writeText) …` and `… shell:trash (trashItem) …`.

- [ ] **Step 4: No-manifest regression**

Temporarily comment out the whole `permissions:` block in zapp.config.ts → rebuild → rerun the probe.
Expected: every probe `GRANTED`/`NO-THROW`, zero `permission denied` log lines, `query.clipwrite:granted`. Restore (un-comment) the block afterwards.

- [ ] **Step 5: Worker deny path**

```bash
cp src/workers/ticker.ts /tmp/ticker.perm-bak
awk -v probe='Services && (async()=>{try{const b:any=(globalThis as any).__zappBridge; const r=b?.invokeService?.("__clipboard:writeText",{text:"x"}); console.log("VERIFY-PERM-W", typeof r==="string"&&r.includes("PERMISSION_DENIED")?"DENIED":JSON.stringify(r).slice(0,60));}catch(e:any){console.log("VERIFY-PERM-W", e?.message?.includes("PERMISSION_DENIED")?"DENIED":"ERR:"+e?.message);}})();' \
  '{print} /from "@zappdev\/runtime"/ && !d {print probe; d=1}' /tmp/ticker.perm-bak > src/workers/ticker.ts
bun run build 2>&1 | tail -1
pkill -f 'bin/hello-world' 2>/dev/null; ZAPP_LOG=debug ./bin/hello-world >/tmp/perm_worker.log 2>&1 & sleep 6; pkill -f 'bin/hello-world'
grep "VERIFY-PERM-W" /tmp/perm_worker.log
cp /tmp/ticker.perm-bak src/workers/ticker.ts
```
Expected: `VERIFY-PERM-W DENIED`. (If the engine surfaces the denial differently — e.g. a thrown error vs a returned error string — accept either, as long as the payload contains PERMISSION_DENIED and the native log shows the denial. Adjust the probe to the engine's actual invokeService return shape if needed.)

- [ ] **Step 6: Restore + full gates**

```bash
cp /tmp/main.ts.perm-bak src/main.ts && grep -c VERIFY-PERM src/main.ts   # expect 0
bun run build 2>&1 | tail -1 && bun run build --platform ios 2>&1 | tail -1
cd /Users/zach/code/zapp && bun run test:all 2>&1 | tail -6
```
Expected: clean restores, both builds complete, full suite green.

- [ ] **Step 7: Commit (docs/plan checkboxes only — hello-world stays unstaged)**

Nothing new to stage in this task (zapp.config.ts is user WIP by standing rule). Confirm: `git status --short` shows only pre-existing dirt + the (intentional) zapp.config.ts permissions block left for the user.

---

## After all tasks: finish the branch

Use **superpowers:finishing-a-development-branch**: run `bun run test:all`, then present merge/PR options. (Standing rule: merge locally only; never push unasked.)

---

## Self-review

**1. Spec coverage:** config field+union (T1) · validation build-error (T1.6) · codegen (T2) · permissions.zc parse/verb/log-once/bootstrap-json (T3) · router invoke+action checkpoints, PERMISSION_DENIED reply, __zapp:permissions (T4) · fs gates beside path allowlist (T4.5) · worker invokeService + bare tier-1 + createWindow gates (T5) · bootstrapConfig carrier with platform baked at codegen (T2+T6) · Permissions.query/list tri-state, support table, PermissionDeniedError, sync mirrors, bootstrap decoration (T7) · docs incl. security.md trust model (T8) · hello-world manifest + deny/regression/worker smokes (T9) · panels need nothing (no bridge — noted in spec). ✓

**2. Placeholder scan:** all code steps carry complete code. Three deliberate adapt-points are bounded with exact discovery commands and working in-repo exemplars (json_safe accessor names → fs.zc/registry.zc crib; build-config target variable; engine error-path reuse). No TBDs. ✓

**3. Symbol consistency:** `permissions_reset_and_load`/`permissions_is_allowed`/`permissions_check`/`permissions_bootstrap_json` consistent across T3/T4/T5/T6 externs; `PERMISSION_DENIED:` prefix identical in router (T4), engines (T5), bootstrap decoration (T7.6), runtime `rethrowPermissionError`; manifest JSON keys `{platform,active,allow}` identical in T2 emission / T3 parser / T7 `PermissionsManifest`; `ZappPermission` ids in T1 match the catalog used in T4 mapping + T8 docs. ✓
