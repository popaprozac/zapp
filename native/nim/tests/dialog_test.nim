import ../dialog

# dialog.nim importc's the darwin_dialog_* symbols (defined in dialog.m, absent
# from a standalone unit test). Stub them to satisfy the link — same pattern as
# fs_test.nim / permissions_test.nim. dialogGrantedPaths is pure (std/json) and
# needs no stub behavior, but the module references the symbols so they must link.
proc darwin_dialog_open_file(o: cstring): cstring {.exportc, cdecl.} = cstring""
proc darwin_dialog_save_file(o: cstring): cstring {.exportc, cdecl.} = cstring""
proc darwin_dialog_message(o: cstring): cstring {.exportc, cdecl.} = cstring""
proc darwin_dialog_open_file_typed(t: cstring, m, d: bool): cstring {.exportc, cdecl.} = cstring""
proc darwin_dialog_save_file_typed(t, n: cstring): cstring {.exportc, cdecl.} = cstring""
proc darwin_dialog_message_typed(m, t: cstring, s: cint): cint {.exportc, cdecl.} = 0.cint
proc darwin_dialog_message_buttons_typed(m, t: cstring, s: cint, b1, b2, b3: cstring): cint {.exportc, cdecl.} = 0.cint

proc test() =
  # cancelled => no paths
  doAssert dialogGrantedPaths("""{"cancelled":true,"paths":["/a"]}""").len == 0
  # picked paths => returned in order
  let g = dialogGrantedPaths("""{"cancelled":false,"paths":["/a/b","/c"]}""")
  doAssert g == @["/a/b", "/c"]
  # missing/empty paths array => []
  doAssert dialogGrantedPaths("""{"cancelled":false}""").len == 0
  doAssert dialogGrantedPaths("""{"cancelled":false,"paths":[]}""").len == 0
  # empty-string entries skipped
  doAssert dialogGrantedPaths("""{"cancelled":false,"paths":["","/x"]}""") == @["/x"]
  # malformed / non-object / empty => []
  doAssert dialogGrantedPaths("{not json").len == 0
  doAssert dialogGrantedPaths("[1,2]").len == 0
  doAssert dialogGrantedPaths("").len == 0
  echo "dialog ok"
test()
