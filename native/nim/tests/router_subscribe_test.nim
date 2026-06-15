import ../events   # eventNameToId lives in events.nim (pure, no importc deps)
proc test() =
  doAssert eventNameToId("window:ready") == 0
  doAssert eventNameToId("window:resize") == 3
  doAssert eventNameToId("window:close") == 5
  doAssert eventNameToId("window:unfullscreen") == 10
  doAssert eventNameToId("resize") == 3
  doAssert eventNameToId("window:bogus") == -1
  echo "router subscribe ok"
test()
