import ../appconfig

# appconfig.nim importc's the CLI-generated dev-tools flag; stub it (1 = dev).
proc zapp_build_dev_tools_default(): cint {.exportc, cdecl.} = 1.cint

proc test() =
  setAppConfig(AppConfig(name: "My App",
                         terminateAfterLastWindowClosed: true,
                         inspectable: Inspectable.Auto,
                         maxWorkers: 4))
  doAssert $app_get_bootstrap_name() == "My App"
  doAssert app_get_bootstrap_max_workers() == 4
  doAssert app_get_bootstrap_application_should_terminate_after_last_window_closed()
  # Auto + dev_tools=1 -> inspectable true
  doAssert app_get_bootstrap_web_content_inspectable()
  setAppConfig(AppConfig(name: "X", terminateAfterLastWindowClosed: false,
                         inspectable: Inspectable.Off, maxWorkers: 0))
  doAssert not app_get_bootstrap_web_content_inspectable()       # Off -> false
  doAssert not app_get_bootstrap_application_should_terminate_after_last_window_closed()
  setAppConfig(AppConfig(name: "Y", terminateAfterLastWindowClosed: true,
                         inspectable: Inspectable.On, maxWorkers: 0))
  doAssert app_get_bootstrap_web_content_inspectable()           # On -> true
  doAssert $app_get_allowed_navigation_json() == ""             # security.zc not ported
  # Inherit at AppConfig level resolves like Auto (tracks the dev-tools flag)
  setAppConfig(AppConfig(name: "Z", terminateAfterLastWindowClosed: true,
                         inspectable: Inspectable.Inherit, maxWorkers: 0))
  doAssert app_get_bootstrap_web_content_inspectable()           # Inherit + dev_tools=1 -> true
  echo "appconfig ok"
test()
