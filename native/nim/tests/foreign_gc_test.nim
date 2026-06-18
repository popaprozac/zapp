# Phase-0 risk gate for worker→native dispatch (#471): does Nim foreign-thread GC
# work on a RAW pthread (not a Nim-created thread) under --mm:orc --threads:on?
# Mirrors what zjs.c's worker pthread will do: setupForeignThreadGc, then alloc +
# parseJson + hand a cstring back (which must stay valid via a threadvar).
import std/[posix, json]

var tlResult {.threadvar.}: string   # per-thread root so the cstring stays alive

proc workerBody(arg: pointer): pointer {.noconv.} =
  setupForeignThreadGc()
  # Allocating Nim work on a foreign thread — the real risk.
  let node = parseJson("""{"msg":"Hello from Zapp!","n":42}""")
  tlResult = node["msg"].getStr & ":" & $node["n"].getInt
  let c = tlResult.cstring                 # borrow the threadvar's buffer
  doAssert $c == "Hello from Zapp!:42"
  tearDownForeignThreadGc()
  result = nil

var tid: Pthread
doAssert pthread_create(addr tid, nil, workerBody, nil) == 0
doAssert pthread_join(tid, nil) == 0
echo "foreign-gc ok"
