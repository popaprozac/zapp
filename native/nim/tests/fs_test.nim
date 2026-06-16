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
