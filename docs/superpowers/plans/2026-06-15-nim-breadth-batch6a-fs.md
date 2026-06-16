# Nim Breadth Batch 6a — fs Leaf Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port `native/fs/fs.zc` → `native/nim/fs.nim` (idiomatic, main-thread) — path-variable expansion + two-source allowlist + gated IO wrappers — add the CLI `fs.allow` codegen for the Nim build, and wire the B5b-deferred shell-path t:4 arms (`openPath`/`showItemInFolder`/`trashItem`, `trashItem` allowlist-gated) into `routeWindowAction`.

**Architecture:** `fs.nim` is plain idiomatic Nim (`std/json`, `string`/`seq`, `strutils`) — the threading investigation confirmed `fs.zc` is reached only on the main thread (bare-fs bypasses it; no `__fs:` webview route), so **no `{.gcsafe.}` / alloc-free discipline**. `fs.nim` owns the allowlist + `$var`/`~` expansion and `importc`s the raw `darwin_fs_*` syscalls from the untouched `fs.m`, plus `darwin_fs_path_var`, the CLI-emitted `zapp_build_fs_allowlist_json`, and `permissions_check` (declared `importc` to avoid an import cycle — exactly as `fs.zc:32-37` declares it `extern`). The shell-path ops live in `routeWindowAction` (B5b shape), gated at the head by the existing `permission_id_for_action`; `trashItem` adds the FS-allowlist gate.

**Tech Stack:** Nim (`std/json`, `std/strutils`), `importc` of `fs.m`/`webview.m` C-ABI, TypeScript/`bun:test` for the CLI codegen.

---

## Background

- **Branch:** `feat/nim-native`. Additive; `zc` path untouched. **macOS / `ZAPP_NATIVE_LANG=nim` build only.**
- **Spec:** `docs/superpowers/specs/2026-06-15-nim-breadth-batch6-leaf-services-design.md` (this is the first leaf, B6a; fs goes first as the shared allowlist dependency).
- **Threading verdict (settled in brainstorm):** `fs.zc` is main-thread-only → `fs.nim` is idiomatic Nim. Confirmed: every `fs_*` caller is a main-thread router/dialog/App path; `runtime/bare/fs.ts` bypasses `fs.zc`; there is no `__fs:` bridge route.
- **The fs.m ↔ fs.zc layering:** `fs.zc`'s gated `fs_*` (expand → allowlist → IO) call `fs.m`'s raw `darwin_fs_*` (POSIX/Foundation, no allowlist). The Nim port keeps that split.
- **`darwin_fs_*` C-ABI (from `native/platform/darwin/fs.h`, all compiled):**
  `const char* darwin_fs_path_var(const char*)`; `char* darwin_fs_read_file(const char*)`;
  `bool darwin_fs_write_file(const char*, const char*)`; `bool darwin_fs_append_file(const char*, const char*)`;
  `bool darwin_fs_exists(const char*)`; `char* darwin_fs_read_dir(const char*)`;
  `bool darwin_fs_mkdir(const char*, bool)`; `bool darwin_fs_remove(const char*)`;
  `bool darwin_fs_rmdir(const char*, bool)`; `bool darwin_fs_rename(const char*, const char*)`;
  `bool darwin_fs_copy(const char*, const char*)`. (`read_file`/`read_dir` return heap `char*` — caller frees.)
- **Shell-path `darwin_*` (in `native/platform/darwin/webview.m:701/718/732`, compiled):**
  `void darwin_show_item_in_folder(const char*)`, `void darwin_open_path(const char*)`, `void darwin_trash_item(const char*)`.
- **Permission gate already in place (B5a):** `permission_id_for_action` (`native/nim/permissions.nim:120`) maps `openPath`→`shell:open`, `showItemInFolder`→`shell:reveal`, `trashItem`→`shell:trash`; `routeWindowAction`'s head runs `permission_id_for_action` + `permissions_check` and drops a denied action. So the shell-path arms are permission-gated at the head; the arm body only adds the FS-allowlist gate on `trashItem` (router.zc:576-593).
- **CLI codegen precedent:** permissions B3 added `zapp_build_permissions_json` to the Nim build-config emitter (`cli/src/build-config.ts:renderBuildConfigNim`, called from `cli/src/native.ts:1109`). fs mirrors it with `zapp_build_fs_allowlist_json` + `zapp_build_fs_persist_grants` (the zc emitter already emits both, `build-config.ts:141-142`).
- **STANDING CONSTRAINTS — never `git add -A`.** Stage only the exact files each task lists. Never `hello-world/`, `vendor/`, `kitchen-sink/`. Never edit `native/platform/**` or `native/worker/engines/*.c`. No `{.emit.}`. Build success ONLY when the last line is `[zapp] build complete: <path>`. Always Bun, never Node. Commit trailer's last line EXACTLY `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `cli/src/build-config.ts` | Nim build-config emitter — add `zapp_build_fs_allowlist_json` + `zapp_build_fs_persist_grants` | Modify (`BuildConfigNimOpts` + `renderBuildConfigNim`) |
| `cli/src/native.ts` | Nim build driver — pass `fsAllowlistJson` / `fsPersistGrants` | Modify (`renderBuildConfigNim` call site, ~1109) |
| `cli/src/build-config-nim.test.ts` | bun:test for the emitter | Modify (2 existing calls) + add 1 test |
| `native/nim/fs.nim` | fs allowlist + path expansion + gated IO (idiomatic, main-thread) | Create |
| `native/nim/tests/fs_test.nim` | Nim unit test for the pure core | Create |
| `native/nim/router.nim` | shell-path t:4 arms in `routeWindowAction` + `import fs` + shell `darwin_*` importc | Modify |

---

## Task 1: CLI fs allowlist + persist-grants codegen (Nim emitter)

**Files:** Modify `cli/src/build-config.ts`, `cli/src/native.ts`, `cli/src/build-config-nim.test.ts`.

- [ ] **Step 1: Write the failing test**

In `cli/src/build-config-nim.test.ts`, add this test at the end of the file:
```ts
test("renderBuildConfigNim emits fs allowlist + persist-grants getters", () => {
  const out = renderBuildConfigNim({
    initialUrl: "zapp://index.html",
    identifier: "com.zapp.test",
    assetRoot: "/tmp/assets",
    embedAssets: false,
    devTools: 1,
    isDev: true,
    permissionsJson: '{"platform":"macos","active":false,"allow":[]}',
    fsAllowlistJson: '["$userData","/tmp/zapp"]',
    fsPersistGrants: true,
  });
  // The allowlist JSON is embedded as a Nim string literal whose VALUE is the
  // raw array (fs.nim's parser reads it via std/json).
  expect(out).toContain('let zappFsAllowlistJson = "[\\"$userData\\",\\"/tmp/zapp\\"]"');
  expect(out).toContain("proc zapp_build_fs_allowlist_json(): cstring {.exportc, cdecl.} = zappFsAllowlistJson.cstring");
  expect(out).toContain("proc zapp_build_fs_persist_grants(): bool {.exportc, cdecl.} = true");
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/zach/code/zapp/cli && bun test src/build-config-nim.test.ts 2>&1 | tail -15`
Expected: the two pre-existing `renderBuildConfigNim` tests FAIL to type-check / the new test FAILS — because `BuildConfigNimOpts` has no `fsAllowlistJson`/`fsPersistGrants` and the emitter emits neither. (TS reports the object literal missing required props OR the `toContain` assertions fail.)

- [ ] **Step 3: Extend `BuildConfigNimOpts`**

In `cli/src/build-config.ts`, in `export interface BuildConfigNimOpts`, add the two fields after `permissionsJson: string;`:
```ts
  permissionsJson: string;
  fsAllowlistJson: string;
  fsPersistGrants: boolean;
```

- [ ] **Step 4: Emit the two getters**

In `cli/src/build-config.ts`, in `renderBuildConfigNim`, add the backing `let` immediately after the `let zappPermissionsJson = ${s(o.permissionsJson)}` line:
```
let zappFsAllowlistJson = ${s(o.fsAllowlistJson)}
```
and add the two procs immediately after the `proc zapp_build_permissions_json(): cstring {.exportc, cdecl.} = zappPermissionsJson.cstring` line:
```
proc zapp_build_fs_allowlist_json(): cstring {.exportc, cdecl.} = zappFsAllowlistJson.cstring
proc zapp_build_fs_persist_grants(): bool {.exportc, cdecl.} = ${o.fsPersistGrants ? "true" : "false"}
```
(`s = (v) => JSON.stringify(v)` is already defined in the function; it turns the raw JSON array string into a valid Nim string literal — same idiom as `zappPermissionsJson`.)

- [ ] **Step 5: Update the two pre-existing test calls**

In `cli/src/build-config-nim.test.ts`, the two existing `renderBuildConfigNim({...})` calls (the "emits exportc getters…" test and the "emits zapp_build_permissions_json…" test) now miss required props. Add to BOTH object literals, after their `permissionsJson:` line:
```ts
    fsAllowlistJson: "[]",
    fsPersistGrants: false,
```

- [ ] **Step 6: Pass the fields from the Nim build driver**

In `cli/src/native.ts`, in the `renderBuildConfigNim({...})` call (~line 1109), add after `permissionsJson: JSON.stringify(permsObj),`:
```ts
    fsAllowlistJson: JSON.stringify(config.fs?.allow ?? []),
    fsPersistGrants: config.fs?.persistDialogGrants ?? false,
```
(`config` is in scope here; the zc path reads the same fields — `build-config.ts:66-68`.)

- [ ] **Step 7: Run the test to verify it passes**

Run: `cd /Users/zach/code/zapp/cli && bun test src/build-config-nim.test.ts 2>&1 | tail -8`
Expected: PASS, 0 fail (all `renderBuildConfigNim`/`renderBootstrapNim`/`renderHeadlessNim` tests green).

- [ ] **Step 8: Type-check the CLI**

Run: `cd /Users/zach/code/zapp && bunx tsc --noEmit -p cli/tsconfig.json 2>&1 | grep -E 'build-config|native\.ts' | head` (or `bun run check` if defined)
Expected: no new errors referencing `build-config.ts` / `native.ts` (a pre-existing baseline of unrelated errors is acceptable — only assert NO new fs-related ones).

- [ ] **Step 9: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/build-config.ts cli/src/native.ts cli/src/build-config-nim.test.ts
git commit -m "$(printf 'feat(nim): emit zapp_build_fs_allowlist_json for the Nim build (Batch 6a)\n\nThe Nim build-config emitter now emits zapp_build_fs_allowlist_json +\nzapp_build_fs_persist_grants (mirrors the zc emitter, build-config.ts:141-142)\nso fs.nim can importc the static fs.allow allowlist. native.ts threads\nconfig.fs.allow / persistDialogGrants through. bun-tested.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 2: fs.nim — path expansion + allowlist + grants + gated IO

**Files:** Create `native/nim/fs.nim`, `native/nim/tests/fs_test.nim`.

- [ ] **Step 1: Write the failing test**

Create `native/nim/tests/fs_test.nim`:
```nim
import ../fs

# fs.nim importc's these (the real symbols live in fs.m / webview.m / the
# CLI-emitted config — absent from a standalone unit test). Stub them to
# satisfy the link, same pattern as permissions_test.nim. darwin_fs_path_var
# returns deterministic roots so fsExpandPath is testable end-to-end.
proc darwin_fs_path_var(name: cstring): cstring {.exportc, cdecl.} =
  let n = $name
  if n == "home": return cstring"/HOME"
  if n == "userData" or n == "appData": return cstring"/UD"
  if n == "temp": return cstring"/TMP"
  return cstring""
proc zapp_build_fs_allowlist_json(): cstring {.exportc, cdecl.} = cstring"[]"
proc darwin_fs_read_file(path: cstring): cstring {.exportc, cdecl.} = cstring""
proc darwin_fs_write_file(path, data: cstring): bool {.exportc, cdecl.} = true
proc darwin_fs_append_file(path, data: cstring): bool {.exportc, cdecl.} = true
proc darwin_fs_exists(path: cstring): bool {.exportc, cdecl.} = true
proc darwin_fs_read_dir(path: cstring): cstring {.exportc, cdecl.} = cstring"[]"
proc darwin_fs_mkdir(path: cstring, recursive: bool): bool {.exportc, cdecl.} = true
proc darwin_fs_remove(path: cstring): bool {.exportc, cdecl.} = true
proc darwin_fs_rmdir(path: cstring, recursive: bool): bool {.exportc, cdecl.} = true
proc darwin_fs_rename(frm, dst: cstring): bool {.exportc, cdecl.} = true
proc darwin_fs_copy(frm, dst: cstring): bool {.exportc, cdecl.} = true
proc permissions_check(id, meth: cstring): bool {.exportc, cdecl.} = true

proc test() =
  # --- path expansion (real fsExpandPath, via the stub resolver) ---
  doAssert fsExpandPath("") == ""
  doAssert fsExpandPath("/abs/p") == "/abs/p"
  doAssert fsExpandPath("~") == "/HOME"
  doAssert fsExpandPath("~/x") == "/HOME/x"
  doAssert fsExpandPath("$home/x") == "/HOME/x"
  doAssert fsExpandPath("$userData") == "/UD"
  doAssert fsExpandPath("$temp/a/b") == "/TMP/a/b"
  doAssert fsExpandPath("$nope/x") == ""              # unknown var -> ""
  # --- static allowlist + prefix-at-boundary matching ---
  fsLoadStaticAllowlist("[\"/tmp/zapp\"]")
  doAssert fsIsAllowed("/tmp/zapp")
  doAssert fsIsAllowed("/tmp/zapp/sub/file")
  doAssert not fsIsAllowed("/tmp/zappX")             # boundary, not a real prefix
  doAssert not fsIsAllowed("/tmp")                   # parent isn't allowed
  doAssert not fsIsAllowed("/tmp/zapp/../etc")       # traversal rejected
  doAssert not fsIsAllowed("")                       # empty rejected
  doAssert not fsIsAllowed("/other")
  # --- $var entries expand through the loader; reload replaces static set ---
  fsLoadStaticAllowlist("[\"$temp\"]")               # -> /TMP
  doAssert fsIsAllowed("/TMP/x")
  doAssert not fsIsAllowed("/tmp/zapp")              # prior static set replaced
  # --- session grants (independent of static reloads) ---
  fsLoadStaticAllowlist("[]")
  doAssert not fsIsAllowed("/granted/dir/f")
  fsGrantPath("/granted/dir")
  doAssert fsIsAllowed("/granted/dir/f")
  doAssert fsIsAllowed("/granted/dir")
  doAssert not fsIsAllowed("/granted/dirX")
  fsGrantPath("/granted/dir")                        # dedupe — no dup, no crash
  doAssert fsIsAllowed("/granted/dir/f")
  # --- malformed json -> empty static set (grants still apply) ---
  fsLoadStaticAllowlist("{not json")
  doAssert not fsIsAllowed("/TMP/x")
  doAssert fsIsAllowed("/granted/dir/f")
  echo "fs ok"
test()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/zach/code/zapp/native/nim/tests && nim c -r --hints:off fs_test.nim 2>&1 | tail -5`
Expected: FAIL — `cannot open file: ../fs` (fs.nim does not exist yet).

- [ ] **Step 3: Create `native/nim/fs.nim`**

Create `native/nim/fs.nim`:
```nim
## Filesystem allowlist + path expansion + gated IO. Port of native/fs/fs.zc.
##
## MAIN-THREAD ONLY. Every fs.zc caller is a main-thread router/dialog/App path;
## bare-fs bypasses this layer (libuv direct) and there is no __fs: webview route
## (verified 2026-06-15). So this is idiomatic Nim — std/json, string/seq — with
## NO gcsafe/alloc-free discipline.
##
## fs.zc's gated fs_* (expand -> allowlist -> IO) call fs.m's raw darwin_fs_*;
## this module keeps that split. permissions_check is declared importc (not an
## `import permissions`) to avoid an import cycle — exactly as fs.zc:32-37
## declares it extern.
import std/[json, strutils]

# --- C-ABI: fs.m raw syscalls + path-var resolver -------------------------
proc darwin_fs_path_var(name: cstring): cstring {.importc, cdecl.}
proc darwin_fs_read_file(path: cstring): cstring {.importc, cdecl.}
proc darwin_fs_write_file(path, data: cstring): bool {.importc, cdecl.}
proc darwin_fs_append_file(path, data: cstring): bool {.importc, cdecl.}
proc darwin_fs_exists(path: cstring): bool {.importc, cdecl.}
proc darwin_fs_read_dir(path: cstring): cstring {.importc, cdecl.}
proc darwin_fs_mkdir(path: cstring, recursive: bool): bool {.importc, cdecl.}
proc darwin_fs_remove(path: cstring): bool {.importc, cdecl.}
proc darwin_fs_rmdir(path: cstring, recursive: bool): bool {.importc, cdecl.}
proc darwin_fs_rename(frm, dst: cstring): bool {.importc, cdecl.}
proc darwin_fs_copy(frm, dst: cstring): bool {.importc, cdecl.}
# CLI-emitted static allowlist (zapp_build_config.nim, Task 1).
proc zapp_build_fs_allowlist_json(): cstring {.importc, cdecl.}
# Permission gate (permissions.nim exportc); importc'd to dodge an import cycle.
proc permissions_check(id, meth: cstring): bool {.importc, cdecl.}
# libc free for the heap char* darwin_fs_read_file/read_dir return.
proc c_free(p: cstring) {.importc: "free", cdecl.}

# --- State (main-thread; idiomatic seqs, no fixed cap) --------------------
var gStaticAllow: seq[string] = @[]
var gSessionGrants: seq[string] = @[]
var gInitDone = false

# --- Path expansion (mirror fs_expand_path, fs.zc:48) ---------------------
proc fsExpandPath*(path: string): string =
  ## Expand `$var/…` and `~/…` to absolute paths. "" for empty input or an
  ## unresolvable var; absolute/relative paths pass through unchanged.
  if path.len == 0: return ""
  if path[0] == '~' and (path.len == 1 or path[1] == '/'):
    let home = $darwin_fs_path_var("home".cstring)
    if home.len == 0: return ""
    return home & path[1 .. ^1]
  if path[0] == '$':
    let slash = path.find('/', 1)
    let name = (if slash < 0: path[1 .. ^1] else: path[1 ..< slash])
    let resolved = $darwin_fs_path_var(name.cstring)
    if resolved.len == 0: return ""
    if slash < 0: return resolved
    return resolved & path[slash .. ^1]
  return path

# --- Allowlist (mirror fs_is_allowed, fs.zc:200) --------------------------
proc isUnderPrefix(resolved, pat: string): bool =
  ## Directory-prefix match: "/a/b" allows "/a/b" and "/a/b/…" but not "/a/bad".
  if pat.len == 0 or resolved.len < pat.len: return false
  if not resolved.startsWith(pat): return false
  result = resolved.len == pat.len or resolved[pat.len] == '/'

proc fsLoadStaticAllowlist*(json: string) =
  ## (Re)load the static allowlist from a JSON array of raw patterns; expand
  ## each and store the resolved form. Test seam + the body of fsEnsureInit.
  ## Marks init done. A parse error / non-array leaves the static set empty.
  gStaticAllow = @[]
  gInitDone = true
  var root: JsonNode
  try: root = parseJson(json)
  except CatchableError: return
  if root.kind != JArray: return
  for elem in root:
    if elem.kind == JString:
      let expanded = fsExpandPath(elem.getStr())
      if expanded.len > 0: gStaticAllow.add(expanded)

proc fsEnsureInit*() =
  ## Lazy init from the CLI-emitted allowlist (main thread; mirror
  ## fs_init_static_allowlist).
  if gInitDone: return
  fsLoadStaticAllowlist($zapp_build_fs_allowlist_json())

proc fsIsAllowed*(resolved: string): bool =
  ## True when `resolved` (already expanded) is under any allowlisted prefix.
  ## Rejects empty + any ".." traversal (so apps can't escape the sandbox).
  fsEnsureInit()
  if resolved.len == 0: return false
  if resolved.contains("/../"): return false
  if resolved.len >= 3 and resolved[^3 .. ^1] == "/..": return false
  for pat in gStaticAllow:
    if isUnderPrefix(resolved, pat): return true
  for pat in gSessionGrants:
    if isUnderPrefix(resolved, pat): return true
  return false

proc fsGrantPath*(path: string) =
  ## Add a path to the session allowlist (Dialog.openFile grant — B6b wires
  ## this). No-op on empty/unresolvable or an exact duplicate.
  let expanded = fsExpandPath(path)
  if expanded.len == 0: return
  for g in gSessionGrants:
    if g == expanded: return
  gSessionGrants.add(expanded)

# --- Gated IO (mirror the fs.zc public API: expand -> allowlist -> perm -> IO)
proc fsReadFile*(path: string): string =
  let abs = fsExpandPath(path)
  if not fsIsAllowed(abs): return ""
  if not permissions_check("fs:read".cstring, "fs".cstring): return ""
  let buf = darwin_fs_read_file(abs.cstring)
  if buf.isNil: return ""
  result = $buf
  c_free(buf)

proc fsWriteFile*(path, data: string): bool =
  let abs = fsExpandPath(path)
  if not fsIsAllowed(abs): return false
  if not permissions_check("fs:write".cstring, "fs".cstring): return false
  darwin_fs_write_file(abs.cstring, data.cstring)

proc fsAppendFile*(path, data: string): bool =
  let abs = fsExpandPath(path)
  if not fsIsAllowed(abs): return false
  if not permissions_check("fs:write".cstring, "fs".cstring): return false
  darwin_fs_append_file(abs.cstring, data.cstring)

proc fsExists*(path: string): bool =
  let abs = fsExpandPath(path)
  if not fsIsAllowed(abs): return false
  if not permissions_check("fs:read".cstring, "fs".cstring): return false
  darwin_fs_exists(abs.cstring)

proc fsReadDir*(path: string): string =
  let abs = fsExpandPath(path)
  if not fsIsAllowed(abs): return ""
  if not permissions_check("fs:read".cstring, "fs".cstring): return ""
  let buf = darwin_fs_read_dir(abs.cstring)
  if buf.isNil: return ""
  result = $buf
  c_free(buf)

proc fsMkdir*(path: string, recursive: bool): bool =
  let abs = fsExpandPath(path)
  if not fsIsAllowed(abs): return false
  if not permissions_check("fs:write".cstring, "fs".cstring): return false
  darwin_fs_mkdir(abs.cstring, recursive)

proc fsRemove*(path: string): bool =
  let abs = fsExpandPath(path)
  if not fsIsAllowed(abs): return false
  if not permissions_check("fs:write".cstring, "fs".cstring): return false
  darwin_fs_remove(abs.cstring)

proc fsRmdir*(path: string, recursive: bool): bool =
  let abs = fsExpandPath(path)
  if not fsIsAllowed(abs): return false
  if not permissions_check("fs:write".cstring, "fs".cstring): return false
  darwin_fs_rmdir(abs.cstring, recursive)

proc fsRename*(frm, dst: string): bool =
  ## rename/copy validate BOTH source and destination (fs.zc:448).
  let absFrom = fsExpandPath(frm)
  let absTo = fsExpandPath(dst)
  if not fsIsAllowed(absFrom) or not fsIsAllowed(absTo): return false
  if not permissions_check("fs:write".cstring, "fs".cstring): return false
  darwin_fs_rename(absFrom.cstring, absTo.cstring)

proc fsCopy*(frm, dst: string): bool =
  let absFrom = fsExpandPath(frm)
  let absTo = fsExpandPath(dst)
  if not fsIsAllowed(absFrom) or not fsIsAllowed(absTo): return false
  if not permissions_check("fs:write".cstring, "fs".cstring): return false
  darwin_fs_copy(absFrom.cstring, absTo.cstring)
```
(Idiomatic wins over the zc: independent Nim strings replace the shared `fs_expand_buf` static + the rename/copy scratch-buffer dance; `$buf` + `c_free` replaces the leak-into-static-slot hack; `seq` replaces the `FS_MAX_ALLOW`-capped C array.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd /Users/zach/code/zapp/native/nim/tests && nim c -r --hints:off fs_test.nim 2>&1 | tail -5`
Expected: last line `fs ok`. (If it fails to LINK on an undefined `darwin_fs_*`/`permissions_check`/`zapp_build_fs_allowlist_json`, a stub signature in the test doesn't match the `fs.nim` importc — align them.)

- [ ] **Step 5: Regression — the other Nim unit tests still pass**

Run: `cd /Users/zach/code/zapp/native/nim/tests && for t in permissions_test router_subscribe_test callbacks_test dispatch_test service_cabi_test; do nim c -r --hints:off $t.nim 2>&1 | tail -1; done`
Expected: each prints its `… ok` line.

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/fs.nim native/nim/tests/fs_test.nim
git commit -m "$(printf 'feat(nim): fs.nim — allowlist + path expansion + gated IO (Batch 6a)\n\nPort of native/fs/fs.zc, idiomatic main-thread Nim ($var/~ expansion,\ntwo-source allowlist with prefix-at-boundary + traversal reject, session\ngrants, gated IO wrapping fs.m darwin_fs_*). permissions_check + the build\nallowlist getter declared importc to avoid an import cycle. Unit-tested\n(expansion + allowlist + grants).\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 3: Wire shell-path t:4 arms into routeWindowAction → build → GATE

**Files:** Modify `native/nim/router.nim`.

- [ ] **Step 1: Add the shell `darwin_*` importc decls + import fs**

In `native/nim/router.nim`, add `fs` to the existing `import` line at the top (it currently imports `bridge, service, clipboard, callbacks, events, permissions`):
```nim
import bridge, service, clipboard, callbacks, events, permissions, fs
```
Then, after the B5b app/shell importc block (the `darwin_open_external` decl), add:
```nim
# --- t:4 shell-path targets (webview.m, compiled; B6a) ---------------------
proc darwin_show_item_in_folder(p: cstring) {.importc, cdecl.}
proc darwin_open_path(p: cstring) {.importc, cdecl.}
proc darwin_trash_item(p: cstring) {.importc, cdecl.}
```

- [ ] **Step 2: Add the shell-path arms in routeWindowAction**

In `routeWindowAction`, immediately AFTER the `openExternal` arm (the `if action == "openExternal": … return` block from B5b) and BEFORE the `# --- handle-based window ops …` comment, insert:
```nim
  # --- shell-path ops (B6a; permission-gated at the head as shell:open/reveal/
  # trash). trashItem ADDS the FS-allowlist gate so JS can't trash an arbitrary
  # path (router.zc:576-593); showItemInFolder/openPath are non-destructive. ---
  if action == "showItemInFolder" or action == "openPath" or action == "trashItem":
    let p = a{"path"}
    if p.isNil: return
    let path = p.getStr("")
    if path.len == 0: return
    let abs = fsExpandPath(path)
    if action == "trashItem":
      if not fsIsAllowed(abs): return
    if action == "showItemInFolder": darwin_show_item_in_folder(abs.cstring)
    elif action == "openPath": darwin_open_path(abs.cstring)
    else: darwin_trash_item(abs.cstring)
    return
```

- [ ] **Step 3: Full Nim build**

Run: `cd /Users/zach/code/zapp/hello-world && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | tail -4`
Expected: last line `[zapp] build complete: <path>`. (Undefined `darwin_show_item_in_folder`/`darwin_open_path`/`darwin_trash_item` → check the importc name vs webview.m; undefined `zapp_build_fs_allowlist_json` → Task 1 didn't emit it / rebuild didn't regen the config; `darwin_fs_*` resolve from fs.m.) Do NOT `git add` hello-world/.

- [ ] **Step 4: Regression — all Nim unit tests**

Run: `cd /Users/zach/code/zapp/native/nim/tests && for t in fs_test permissions_test router_subscribe_test callbacks_test dispatch_test appconfig_test service_cabi_test; do [ -f $t.nim ] && nim c -r --hints:off $t.nim 2>&1 | tail -1; done`
Expected: each prints its `… ok` line (incl. `fs ok`).

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/router.nim
git commit -m "$(printf 'feat(nim): t:4 shell-path arms (openPath/showItemInFolder/trashItem) (Batch 6a)\n\nrouteWindowAction now dispatches the B5b-deferred shell-path ops via\nwebview.m darwin_show_item_in_folder/open_path/trash_item, with fs.nim path\nexpansion and the FS-allowlist gate on trashItem (router.zc:576-593).\nCloses the B5b shell-path deferral.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

- [ ] **Step 6: GATE — human smoke (controller pauses here)**

Build + regression gates prove fs.nim + the CLI allowlist getter + the router wiring all link. Optional runtime confirmation (`ZAPP_NATIVE_LANG=nim bun run dev`):
1. A "reveal in Finder" control (`showItemInFolder`) opens Finder at the item; an "open path" control (`openPath`) opens it.
2. `trashItem` on an **allowlisted** path (under `zapp.config.ts` `fs.allow`, or a dialog-granted path once B6b lands) moves it to Trash; `trashItem` on a **non-allowlisted** path is silently refused (no trash).

Note: the gated IO surface (`fsReadFile`/`fsWriteFile`/…) has no webview route in the Nim build (parity with the zc — the webview never had one; bare workers bypass fs.zc), so it is **build-verified only** this batch; it becomes runtime-exercisable when a native-first App.fs caller lands.

Do not proceed to the final review until the human confirms (or accepts the build+regression gate).

---

## Self-Review

**1. Spec coverage** (against the spec's fs section):
- `fs.nim` idiomatic main-thread, `$var`/`~` expansion → Task 2 `fsExpandPath`. ✓
- Two-source allowlist (static from config + runtime grants) + `fsIsAllowed` → Task 2. ✓
- Gated IO wrappers calling `darwin_fs_*` (full surface for parity) → Task 2. ✓
- CLI `fs.allow` codegen mirroring permissions → Task 1. ✓
- Shell-path t:4 arms (openPath/showItemInFolder/trashItem), trashItem allowlist-gated, closes B5b → Task 3. ✓
- `fsGrantPath` exposed for B6b → Task 2 (`fsGrantPath*`). ✓
- Pure logic unit-tested; routes build+runtime gated → Tasks 2/3. ✓

**2. Placeholder scan:** No TBD/TODO. Every code step is complete. The "or `bun run check`" in Task 1 Step 8 is an alternative invocation, not a placeholder.

**3. Type consistency:** `BuildConfigNimOpts` gains `fsAllowlistJson: string` + `fsPersistGrants: boolean`, set at all three call sites (2 tests + native.ts) — matched. `fsExpandPath`/`fsIsAllowed`/`fsGrantPath`/`fsLoadStaticAllowlist`/`fsEnsureInit` signatures used in `fs_test.nim` and `router.nim` match their `fs.nim` definitions. The `darwin_fs_*`/`permissions_check`/`zapp_build_fs_allowlist_json`/`c_free` importc signatures in `fs.nim` match the `fs_test.nim` exportc stubs (param/return types identical) and the real `fs.h`/`webview.m`/`permissions.nim`/CLI getter. The shell `darwin_*` importc (`p: cstring`) matches webview.m's `const char*`. ✓
