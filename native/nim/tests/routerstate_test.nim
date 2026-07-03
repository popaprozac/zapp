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

# --- chrome persistence (R2' #771 T8) ----------------------------------------
# Window 11: push with chrome JSON → persisted; pop/forward replay it.
block:
  routerSeed(11, "/")
  doAssert routerCurrentChrome(11) == "", "seed entry has no chrome"
  routerPush(11, "/clean", "", "{\"navbarHidden\":true}")
  doAssert routerCurrentChrome(11) == "{\"navbarHidden\":true}", "push stores chrome"
  discard routerPop(11)
  doAssert routerCurrentChrome(11) == "", "pop: back to the chrome-less seed"
  discard routerForward(11)
  doAssert routerCurrentChrome(11) == "{\"navbarHidden\":true}",
    "forward replays the entry's push-time chrome"

# Window 12: default param (old 3-arg call shape) stores "" chrome; push after
# pop truncates the forward entry's chrome along with the entry.
block:
  routerSeed(12, "/")
  routerPush(12, "/a", "")                              # no chrome arg → ""
  doAssert routerCurrentChrome(12) == "", "3-arg push stores empty chrome"
  routerPush(12, "/b", "", "{\"title\":\"B\"}")
  discard routerPop(12)
  routerPush(12, "/c", "")                              # truncates /b (and its chrome)
  doAssert routerCurrentChrome(12) == "", "truncating push drops stale chrome"
  doAssert not routerCanGoForward(12), "forward truncated"

# Window 13: replace resets chrome (options are push-only by contract).
block:
  routerSeed(13, "/")
  routerPush(13, "/x", "", "{\"title\":\"X\"}")
  routerReplace(13, "/y", "")
  doAssert routerCurrentChrome(13) == "", "replace resets chrome to defaults"

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

echo "routerstate ok"
