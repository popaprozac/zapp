## Unit tests for routerstate.nim — per-window route stack with browser-history
## semantics. Pure logic; no native/importc dependencies.
## Each test block uses an isolated window id so state doesn't bleed between cases.
import ../routerstate

# --- seed → initial state ---------------------------------------------------
# Window 1: verify seed sets the url and both nav flags are false.
routerSeed(1, "/home")
doAssert routerCurrentUrl(1) == "/home", "seed url must be current"
doAssert routerCurrentParams(1) == "", "seed params must be empty"
doAssert not routerCanGoBack(1), "no back after seed"
doAssert not routerCanGoForward(1), "no forward after seed"

# --- push/push → current, canGoBack=true, canGoForward=false ----------------
# Window 2: seed "/a", push "/b" → two entries, at head.
routerSeed(2, "/a")
routerPush(2, "/b", "")
doAssert routerCurrentUrl(2) == "/b", "current must be /b after push"
doAssert routerCanGoBack(2), "can go back after push"
doAssert not routerCanGoForward(2), "no forward at head"

# --- pop → forward preserved, canGoBack=false (at root) ---------------------
# Window 3: seed "/a", push "/b", pop → back at root.
routerSeed(3, "/a")
routerPush(3, "/b", "")
discard routerPop(3)
doAssert routerCurrentUrl(3) == "/a", "pop: back to /a"
doAssert not routerCanGoBack(3), "at root after pop: no back"
doAssert routerCanGoForward(3), "forward to /b preserved after pop"

# --- forward ----------------------------------------------------------------
# Continuing window 3: forward → back to /b.
discard routerForward(3)
doAssert routerCurrentUrl(3) == "/b", "forward: back to /b"
doAssert not routerCanGoForward(3), "at head after forward: no forward"

# --- pop then push truncates forward ----------------------------------------
# Window 4: seed "/a", push "/b", pop, push "/c" → forward truncated.
routerSeed(4, "/a")
routerPush(4, "/b", "")
discard routerPop(4)
routerPush(4, "/c", "")
doAssert routerCurrentUrl(4) == "/c", "push /c after pop: current is /c"
doAssert not routerCanGoForward(4), "forward truncated after push /c"
doAssert routerCanGoBack(4), "can go back to /a after push /c"

# --- replace in-place (forward preserved) -----------------------------------
# Window 5: seed "/x", push "/y", pop (forward=/y available), replace "/z".
routerSeed(5, "/x")
routerPush(5, "/y", "")
discard routerPop(5)
doAssert routerCanGoForward(5), "sanity: forward available before replace"
routerReplace(5, "/z", "")
doAssert routerCurrentUrl(5) == "/z", "replace: current is /z"
doAssert routerCanGoForward(5), "replace preserves forward (/y still in stack)"
doAssert not routerCanGoBack(5), "replace at root: still no back"

# --- popToRoot --------------------------------------------------------------
# Window 6: build a multi-entry stack, popToRoot → seed url, no forward.
routerSeed(6, "/root")
routerPush(6, "/p1", "")
routerPush(6, "/p2", "")
doAssert routerPopToRoot(6), "popToRoot returns true when not already at root"
doAssert routerCurrentUrl(6) == "/root", "popToRoot: current is seed url"
doAssert not routerCanGoBack(6), "popToRoot: no back"
doAssert not routerCanGoForward(6), "popToRoot: no forward (stack truncated)"

# --- params round-trip ------------------------------------------------------
# Window 7: push with JSON params, read them back.
routerSeed(7, "/start")
routerPush(7, "/d", "{\"id\":42}")
doAssert routerCurrentUrl(7) == "/d", "url with params"
doAssert routerCurrentParams(7) == "{\"id\":42}", "params round-trip"

# --- pop at root: no-op, returns false, no crash ----------------------------
routerSeed(8, "/only")
doAssert not routerPop(8), "pop at root returns false"
doAssert routerCurrentUrl(8) == "/only", "pop at root: url unchanged"

# --- forward at head: no-op, returns false, no crash ------------------------
routerSeed(9, "/head")
doAssert not routerForward(9), "forward at head returns false"
doAssert routerCurrentUrl(9) == "/head", "forward at head: url unchanged"

# --- clear: subsequent readers return safe empty sentinels ------------------
routerSeed(10, "/temp")
routerClear(10)
doAssert routerCurrentUrl(10) == "", "after clear: url is empty sentinel"
doAssert routerCurrentParams(10) == "", "after clear: params is empty"
doAssert not routerCanGoBack(10), "after clear: no back"
doAssert not routerCanGoForward(10), "after clear: no forward"

# --- routerDepth + router_current_url (N3a iOS read accessors) ---------------
block:
  routerSeed(901, "/")
  doAssert routerDepth(901) == 1
  doAssert $routerCurrentUrlC(901) == "/"
  routerPush(901, "/a", "")
  doAssert routerDepth(901) == 2
  doAssert $routerCurrentUrlC(901) == "/a"
  routerPush(901, "/b", "")
  doAssert routerDepth(901) == 3
  discard routerPop(901)
  doAssert routerDepth(901) == 2          # cursor moved back; forward preserved
  doAssert $routerCurrentUrlC(901) == "/a"
  routerClear(901)
  doAssert routerDepth(901) == 0

# --- routerSeedEmpty + owned-nav seeding (R1) ---------------------------------
# Window 902: empty seed → depth=0 (sidebar-only at launch).
block:
  routerSeedEmpty(902)
  doAssert routerDepth(902) == 0, "empty seed: depth must be 0 (sidebar-only)"
  doAssert routerCurrentUrl(902) == "", "empty seed: no current url"
  doAssert not routerCanGoBack(902), "empty seed: no back"
  doAssert not routerCanGoForward(902), "empty seed: no forward"

  # popToRoot on empty state: no-op (returns false, no crash)
  doAssert not routerPopToRoot(902), "popToRoot on empty: returns false (no-op)"
  doAssert routerDepth(902) == 0, "popToRoot on empty: depth still 0"

  # replace on empty state: treats as first entry (sidebar-pane first-select path)
  routerReplace(902, "/section-a", "")
  doAssert routerDepth(902) == 1, "replace on empty: depth becomes 1"
  doAssert routerCurrentUrl(902) == "/section-a", "replace on empty: url set"

  # routerSeed after empty+replace: no-op (hasKey is true)
  routerSeed(902, "/")
  doAssert routerCurrentUrl(902) == "/section-a", "seed after empty+replace: no-op"
  doAssert routerDepth(902) == 1, "seed after empty+replace: depth unchanged"

  # routerSeedEmpty on existing window: no-op
  routerSeedEmpty(902)
  doAssert routerDepth(902) == 1, "routerSeedEmpty on existing: no-op"

  routerClear(902)

# Window 903: owned-nav full flow simulation
#   seed empty → popToRoot (no-op) → replace(section) → push(detail) → pop
block:
  routerSeedEmpty(903)
  doAssert routerDepth(903) == 0
  discard routerPopToRoot(903)              # sidebar-pane first-tap: popToRoot no-op
  doAssert routerDepth(903) == 0
  routerReplace(903, "/section-b", "")     # first section select
  doAssert routerDepth(903) == 1
  doAssert routerCurrentUrl(903) == "/section-b"
  routerPush(903, "/detail", "")           # drill-down
  doAssert routerDepth(903) == 2
  discard routerPop(903)                   # back from detail
  doAssert routerDepth(903) == 1
  doAssert routerCurrentUrl(903) == "/section-b"
  routerClear(903)

echo "routerstate ok"
