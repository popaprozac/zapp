import ../permissions

# permissions.nim importc's zapp_build_permissions_json (the CLI-generated getter).
# Never CALLED here (every test drives permissionsResetAndLoad directly), but
# permissionsEnsureInit references it, so stub it to satisfy the link — same as
# callbacks_test.nim stubs zapp_dispatch_event_to_js.
proc zapp_build_permissions_json(): cstring {.exportc, cdecl.} =
  cstring("{\"platform\":\"macos\",\"active\":false,\"allow\":[]}")

proc test() =
  # inactive => allow all
  permissionsResetAndLoad("{\"platform\":\"macos\",\"active\":false,\"allow\":[]}")
  doAssert permissionsIsAllowed(cstring"clipboard:read")
  doAssert permissionsIsAllowed(cstring"tray")
  # active + empty => deny all
  permissionsResetAndLoad("{\"platform\":\"macos\",\"active\":true,\"allow\":[]}")
  doAssert not permissionsIsAllowed(cstring"clipboard:read")
  # bare module grants its verbs
  permissionsResetAndLoad("{\"platform\":\"macos\",\"active\":true,\"allow\":[\"clipboard\"]}")
  doAssert permissionsIsAllowed(cstring"clipboard:read")
  doAssert permissionsIsAllowed(cstring"clipboard:write")
  doAssert permissionsIsAllowed(cstring"clipboard")
  doAssert not permissionsIsAllowed(cstring"fs:read")
  # exact verb grant, no sibling/bare bleed
  permissionsResetAndLoad("{\"platform\":\"macos\",\"active\":true,\"allow\":[\"fs:read\",\"shell:open\"]}")
  doAssert permissionsIsAllowed(cstring"fs:read")
  doAssert not permissionsIsAllowed(cstring"fs:write")
  doAssert not permissionsIsAllowed(cstring"fs")
  doAssert permissionsIsAllowed(cstring"shell:open")
  doAssert not permissionsIsAllowed(cstring"shell:trash")
  # malformed => fail open (inactive)
  permissionsResetAndLoad("{not json")
  doAssert permissionsIsAllowed(cstring"clipboard")
  # permission_id_for_invoke mapping (router.zc:21-36 parity)
  doAssert $permission_id_for_invoke(cstring"__clipboard:readText") == "clipboard:read"
  doAssert $permission_id_for_invoke(cstring"__clipboard:has") == "clipboard:read"
  doAssert $permission_id_for_invoke(cstring"__clipboard:writeText") == "clipboard:write"
  doAssert $permission_id_for_invoke(cstring"__dialog:open") == "dialog"
  doAssert $permission_id_for_invoke(cstring"__notif:show") == "notifications"
  doAssert $permission_id_for_invoke(cstring"__shortcuts:register") == "shortcuts"
  doAssert $permission_id_for_invoke(cstring"__screen:list") == "screen"
  doAssert $permission_id_for_invoke(cstring"__window:create") == "window:create"
  doAssert $permission_id_for_invoke(cstring"greet") == ""
  # permissions_check delegates to isAllowed
  permissionsResetAndLoad("{\"platform\":\"macos\",\"active\":true,\"allow\":[\"clipboard\"]}")
  doAssert permissions_check(cstring"clipboard:read", cstring"Clipboard.read")
  doAssert not permissions_check(cstring"fs:read", cstring"fs")
  echo "permissions ok"
test()
