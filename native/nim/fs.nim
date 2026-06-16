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
