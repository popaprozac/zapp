import ../worker_service
# service_invoke_native takes (app, method, args). Bench handlers ignore args → pass nil.
# noop/echo return the constant; unknown -> "".
proc test() =
  registerWorkerServices()
  doAssert $service_invoke_native(nil, cstring"noop", nil) == "{\"ok\":1}"
  doAssert $service_invoke_native(nil, cstring"echo", nil) == "{\"ok\":1}"
  doAssert $service_invoke_native(nil, cstring"missing", nil) == ""
  echo "worker_service ok"
test()
