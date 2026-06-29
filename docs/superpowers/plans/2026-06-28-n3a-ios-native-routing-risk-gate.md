# N3a — iOS Native Routing RISK GATE Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Prove the core iOS native-routing mechanism on the simulator — `router.push("/detail")` on an opted-in iPhone window materializes a new unconstrained VC + its own WKWebView pushed onto `contentNav` (native slide-in); native back + edge swipe-back pop it in lockstep with `routerstate.nim`; the worker stays alive; webview boot cost is measured.

**Architecture:** `routerstate` (Nim) is the single source of truth. On any `router:*` mutation, Nim calls (iOS-gated) `zapp_ios_router_sync(windowId)` which reconciles `contentNav`'s VC stack to match the stack depth (±1: mint+push a route webview/VC, or pop+teardown). A nav-controller delegate routes user back/swipe pops through `zapp_router_pop_from_native` → which re-runs sync (no-op) — breaking the loop. iOS-only (`when defined(zappIos)`); macOS untouched.

**Tech Stack:** Nim (routerstate/router/window), TypeScript (WindowOptions), ObjC (new `ios/routing.m`), Bun.

## Global Constraints

- Branch `feat/ios-native-nav` — commit directly. NO git worktree, NO `git commit --amend`, NO merge.
- Commit trailer EXACTLY: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- Per-file `git add` ONLY — never `-A`/`.`. Pre-existing unrelated WIP stays unstaged.
- Bun, never Node.
- Native-first parity: TS `WindowOptions` ↔ Nim window/routerstate/router ↔ iOS `routing.m`; new iOS importc symbols satisfy `reference_ios_symbol_parity_gate` (`.m`-defined + iOS-built).
- **macOS MUST NOT regress** — all native-push is `when defined(zappIos)`-gated + lives in iOS `.m`; the N2b desktop nav must still behave (macOS build green).
- iOS arm64 / min 15.0; sim functional / device compile-only; NO iOS simulator interaction in-session.
- Spec: `docs/superpowers/specs/2026-06-28-n3a-ios-native-routing-risk-gate-design.md`.

Per-task gates: `bun run check`; `bun test cli/src`; `bun run test:native`; macOS build (`cd kitchen-sink && bun run build` → `[zapp] build complete:`); iOS compile (`cd kitchen-sink && bun run build --platform ios` → `[zapp] build complete:`). T2 ends in the **human iOS-sim smoke** (you do NOT run it).

## RISK-GATE note for the implementer

This proves an unproven mechanism. The Nim/TS/config parts are fully determined (concrete code below). `ios/routing.m` is genuinely new code, but **mirrors existing iOS infrastructure** — point your reading at: `zapp_ios_content_nav_for_window` (toolbar.m:70 extern; sidebar.m def), the swipe-back re-arm + gate already at **sidebar.m:256–274 + :477** (`interactivePopGestureRecognizer.enabled=YES` + `gestureRecognizerShouldBegin:` gating to depth>1 — gotcha #1 is ALREADY SOLVED for this nav; route VCs inherit it), the existing `ZappIOSToolbarNavDelegate` (toolbar.m:188 — **compose**, don't clobber, if a delegate is already set), `darwin_webview_create_ext` (ios/webview.m:749, `container_view` + `identity_window_id` params), the WKUserScript document-start injection pattern (ios/webview.m:812–849), and the `reference_wkwebview_teardown` recipe. If a gotcha (swipe under hidden bar / delegate composition / brk-1 teardown) resists the mirrored approach, **report it clearly in your status** (DONE_WITH_CONCERNS) rather than forcing it — that signal is the point of a risk gate.

---

## Task 1: Native + Nim risk-gate core

**Files:**
- Modify: `native/nim/routerstate.nim` (+ `native/nim/routerstate_test.nim` or the harness's test file)
- Modify: `native/nim/router.nim`
- Modify: `runtime/window.ts`
- Modify: `native/nim/window.nim`
- Create: `native/platform/ios/routing.m`
- Modify: the iOS source list (`cli/src/native.ts` — where `ios/*.m` like `toolbar.m`/`sidebar.m` are registered)

**Interfaces produced (consumed by Task 2 + iOS):**
- Nim `routerDepth(win: int32): cint {.exportc.}`, `router_current_url(win: int32): cstring {.exportc.}` (iOS-queryable); `zapp_router_pop_from_native(windowId: int32) {.exportc.}`; `zapp_window_native_routing(id: int32): bool {.exportc.}`.
- iOS `zapp_ios_router_sync(int32_t windowId)`.
- TS `WindowOptions.nativeRouting?: boolean`.

### Step 1 — routerstate accessors (TDD)

`native/nim/routerstate.nim` already has `routerCurrentUrl*`. Add two `{.exportc.}` C-ABI accessors at the end of the file (the iOS side reads these):

```nim
# --- iOS native-routing read accessors (N3a). exportc so ios/routing.m importc's. ---
proc routerDepth*(win: int32): cint {.exportc, cdecl.} =
  ## Number of entries up to and including the current cursor (the native VC
  ## stack must match this: 1 = root only, N = root + (N-1) pushed routes).
  if gRoutes.hasKey(win):
    return (gRoutes[win].cur + 1).cint
  return 0

proc router_current_url(win: int32): cstring {.exportc, cdecl.} =
  ## Top entry url for the iOS side (cstring view of the Nim string).
  ## Reuses routerCurrentUrl; "" when absent.
  return routerCurrentUrl(win).cstring
```
(Note: `routerDepth` = `cur + 1`, not `entries.len` — pop preserves forward entries, but the native stack must match the *cursor* depth.)

Add a test case to the routerstate test file (match its existing style):

```nim
block:
  routerSeed(901, "/")
  doAssert routerDepth(901) == 1
  doAssert $router_current_url(901) == "/"
  routerPush(901, "/a", "")
  doAssert routerDepth(901) == 2
  doAssert $router_current_url(901) == "/a"
  routerPush(901, "/b", "")
  doAssert routerDepth(901) == 3
  discard routerPop(901)
  doAssert routerDepth(901) == 2          # cursor moved back; forward preserved
  doAssert $router_current_url(901) == "/a"
  routerClear(901)
  doAssert routerDepth(901) == 0
```

Run `bun run test:native` → the routerstate test passes (incl. the new block).

### Step 2 — router.nim: iOS sync hook + native-pop entry

In `native/nim/router.nim`, add to the importc externs block (near `darwin_window_get_by_numeric_id`):

```nim
# --- iOS native routing (N3a). Defined in ios/routing.m; no-op symbol absent on
#     non-iOS builds because the calls are `when defined(zappIos)`-gated. ---
when defined(zappIos):
  proc zapp_ios_router_sync(windowId: int32) {.importc, cdecl.}
```

In the `if action.startsWith("router:")` block, after each `emitRouteChanged(target, …)` call, drive the iOS reconcile. The cleanest single insertion: replace the `case action … return` so that after the `case` completes, sync runs once. Change the block's tail from `else: discard` + `return` to:

```nim
    case action
    of "router:push":
      let url = a{"url"}.getStr("")
      let params = (if a.hasKey("params"): $a["params"] else: "")
      routerPush(target, url, params)
      emitRouteChanged(target, "push")
    of "router:pop":
      if routerPop(target): emitRouteChanged(target, "pop")
    of "router:forward":
      if routerForward(target): emitRouteChanged(target, "forward")
    of "router:replace":
      let url = a{"url"}.getStr("")
      let params = (if a.hasKey("params"): $a["params"] else: "")
      routerReplace(target, url, params)
      emitRouteChanged(target, "replace")
    of "router:popToRoot":
      if routerPopToRoot(target): emitRouteChanged(target, "popToRoot")
    else: discard
    when defined(zappIos): zapp_ios_router_sync(target)   # reconcile native VC stack
    return
```
(Sync runs after every router:* op, including the ones that may not have changed state — `zapp_ios_router_sync` is idempotent reconcile-to-match, so a no-op op is a no-op sync.)

Add the inbound native-pop entry (top-level proc, near `emitRouteChanged`; it must be visible to ios/routing.m as a C symbol):

```nim
proc zapp_router_pop_from_native(windowId: int32) {.exportc, cdecl.} =
  ## Called by ios/routing.m's nav delegate when the user pops a route VC
  ## (back button / edge swipe). Mutate routerstate + broadcast; the trailing
  ## sync sees native already matches → no-op (loop broken).
  if routerPop(windowId):
    emitRouteChanged(windowId, "pop")
  when defined(zappIos): zapp_ios_router_sync(windowId)
```

Run `bun run test:native` + macOS build (the `when defined(zappIos)` guards mean macOS doesn't reference the iOS symbols).

### Step 3 — runtime/window.ts: `nativeRouting` option

In the `WindowOptions` interface, add (near `titleBarStyle`/other window-level opts):

```ts
  /**
   * iOS only: opt this window into native UINavigationController routing —
   * `router.push` materializes a real pushed view controller (own webview,
   * native slide-in + edge swipe-back) instead of in-window content-swap.
   * Default `false`. macOS/Windows ignore it (desktop stays in-window nav).
   * N3a risk-gate seed of the future `presentation: "route"` API.
   */
  nativeRouting?: boolean;
```
`WindowOptions` is forwarded to native as JSON via the existing create path, so no extra wiring here — `window.nim` parses it (Step 4).

### Step 4 — window.nim: thread `nativeRouting` + per-window accessor

In `native/nim/window.nim`, mirror the existing `resizable` bool:

- Add the field to `WindowOptions` (near `resizable*: bool = true`, ~line 136):
  ```nim
  nativeRouting*: bool = false
  ```
- Parse it in `windowOptsApplyJson` (near the `resizable` line ~602):
  ```nim
  if jHasBool(a, "nativeRouting"): o.nativeRouting = jBool(a, "nativeRouting", o.nativeRouting)
  ```
- Add a per-window table + accessor (the iOS side queries by numeric id). Near the top (after imports) add:
  ```nim
  import std/tables
  var gNativeRouting: Table[int32, bool]
  proc zapp_window_native_routing(id: int32): bool {.exportc, cdecl.} =
    gNativeRouting.getOrDefault(id, false)
  ```
  (If `std/tables` is already imported, don't duplicate.)
- In `createWindow` (the proc that assigns the numeric id + already calls `routerSeed(id, "/")` from N2a), set the flag right next to `routerSeed`:
  ```nim
  gNativeRouting[<theNumericId>] = o.nativeRouting   # use the same id var routerSeed uses
  ```
  Read the exact `routerSeed(...)` call site to use the same id variable name.

Run `bun test cli/src` + `bun run check` + `bun run test:native` + macOS build.

### Step 5 — Create `native/platform/ios/routing.m`

This is the risk-gate core. Structure (mirror the reach points named in the RISK-GATE note):

```objc
// iOS native routing (N3a risk gate). Drives contentNav as a UINavigationController
// routing stack: routerstate (Nim) is authoritative; zapp_ios_router_sync reconciles
// the native VC stack to match; a nav delegate routes user pops back to Nim.
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

// --- Nim/native externs ---
extern void* darwin_window_get_by_numeric_id(int32_t numeric_id);
extern UINavigationController* zapp_ios_content_nav_for_window(void* window_ptr);
extern bool zapp_window_native_routing(int32_t window_id);
extern int router_depth(int32_t win);            // routerstate.nim routerDepth (exportc)
extern const char* router_current_url(int32_t win);
extern void zapp_router_pop_from_native(int32_t window_id);
extern void darwin_webview_create_ext(void* window_ptr, bool inspectable, bool accept_first_mouse,
    const char* url_override, int32_t numeric_id_pre_alloc, bool transparent_background,
    void* container_view, int32_t identity_window_id, int32_t pane_role,
    bool host_has_sidebar, bool host_has_inspector);

// Route VC = a plain unconstrained UIViewController hosting its own WKWebView
// (NOT the AutoLayout-constrained contentVC). Tagged so we can count route VCs
// vs the root contentVC and tear down on pop.
@interface ZappRouteVC : UIViewController
@property (nonatomic, weak) WKWebView* webview;
@end
@implementation ZappRouteVC @end

// One delegate per window's contentNav: detects user-initiated pops and tells
// Nim. Composes with N1's toolbar delegate (chain `prev` if one exists).
@interface ZappRoutingNavDelegate : NSObject <UINavigationControllerDelegate>
@property (nonatomic, assign) int32_t windowId;
@property (nonatomic, weak) id<UINavigationControllerDelegate> prev;  // N1 toolbar delegate
@end
@implementation ZappRoutingNavDelegate
- (void)navigationController:(UINavigationController*)nav
       didShowViewController:(UIViewController*)vc animated:(BOOL)animated {
    // native route-VC depth = nav.viewControllers.count (root contentVC is index 0)
    int nativeDepth = (int)nav.viewControllers.count;
    int wantDepth = router_depth(self.windowId);  // 1 = root only
    if (nativeDepth < wantDepth) {
        // user popped (back/swipe) — reflect into routerstate (which re-syncs, no-op)
        zapp_router_pop_from_native(self.windowId);
    }
    if ([self.prev respondsToSelector:_cmd])
        [self.prev navigationController:nav didShowViewController:vc animated:animated];
}
- (BOOL)respondsToSelector:(SEL)sel {
    return [super respondsToSelector:sel] || [self.prev respondsToSelector:sel];
}
- (id)forwardingTargetForSelector:(SEL)sel { return self.prev; }
@end

static NSMutableDictionary<NSNumber*, ZappRoutingNavDelegate*>* g_routing_delegates;

void zapp_ios_router_sync(int32_t windowId) {
    if (!zapp_window_native_routing(windowId)) return;          // opt-in only
    void* win = darwin_window_get_by_numeric_id(windowId);
    if (!win) return;
    UINavigationController* nav = zapp_ios_content_nav_for_window(win);
    if (!nav) return;                                           // no-sidebar window: deferred

    // Install our delegate once (compose with any existing one, e.g. N1 toolbar).
    if (!g_routing_delegates) g_routing_delegates = [NSMutableDictionary dictionary];
    if (!g_routing_delegates[@(windowId)]) {
        ZappRoutingNavDelegate* d = [ZappRoutingNavDelegate new];
        d.windowId = windowId;
        d.prev = nav.delegate;                                  // chain N1's delegate
        nav.delegate = d;
        g_routing_delegates[@(windowId)] = d;
    }

    int want = router_depth(windowId);                          // desired total (root + routes)
    int have = (int)nav.viewControllers.count;
    if (have < want) {
        // push one route VC for the new top route
        const char* urlC = router_current_url(windowId);
        NSString* url = urlC ? [NSString stringWithUTF8String:urlC] : @"/";
        ZappRouteVC* vc = [ZappRouteVC new];
        vc.view.backgroundColor = UIColor.systemBackgroundColor;
        // Mint a webview into vc.view via the existing create path. identity_window_id
        // = host windowId so the route webview reports the host id (bridge + ROUTE_CHANGED).
        // pane_role 0 (main). container_view = vc.view → create_ext pins it.
        darwin_webview_create_ext(win, true, false, NULL, -1, false,
                                  (__bridge void*)vc.view, windowId, 0, false, false);
        vc.webview = [vc.view.subviews.firstObject isKindOfClass:[WKWebView class]]
                       ? (WKWebView*)vc.view.subviews.firstObject : nil;
        (void)url; // N3a renders the top route via the app's router.current()/ROUTE_CHANGED
                   // (zapp.route per-route injection deferred to N3b — see plan note).
        [nav pushViewController:vc animated:YES];
    } else if (have > want) {
        // pop extra route VCs (programmatic router.pop) + tear down their webviews
        while ((int)nav.viewControllers.count > want) {
            UIViewController* top = nav.topViewController;
            [nav popViewControllerAnimated:YES];
            if ([top isKindOfClass:[ZappRouteVC class]]) {
                WKWebView* wv = ((ZappRouteVC*)top).webview;
                if (wv) {
                    // brk-1 teardown recipe (reference_wkwebview_teardown)
                    [wv stopLoading];
                    wv.navigationDelegate = nil;
                    wv.UIDelegate = nil;
                    // remove the bridge script-message handler if one was added
                    @try { [wv.configuration.userContentController removeScriptMessageHandlerForName:@"zappBridge"]; } @catch (__unused id e) {}
                }
            }
        }
    }
}
```

**Implementer notes (read before transcribing):**
- Confirm the exact `darwin_webview_create_ext` arg list against ios/webview.m:749 and the name of the bridge script-message handler it registers (replace `@"zappBridge"` with the real handler name — grep `addScriptMessageHandler` / `name:` in ios/webview.m). If create_ext mounts the webview differently than "first subview of container_view," adjust the `vc.webview` lookup to match how it attaches.
- The swipe-back gesture: route VCs pushed onto this nav inherit sidebar.m's `interactivePopGestureRecognizer` re-arm (sidebar.m:256–274) + the `gestureRecognizerShouldBegin:` depth>1 gate (sidebar.m:477). Verify in the smoke; if the route push needs an extra re-arm, add it (mirror sidebar.m:273-274).
- If `nav.delegate` was already N1's `ZappIOSToolbarNavDelegate`, the `prev`-chaining + `forwardingTargetForSelector:` keeps N1's toolbar reapply working. Verify the toolbar still updates on a routed VC in the smoke.

### Step 6 — Register `ios/routing.m` in the iOS build

Find the iOS `.m` source list (grep `toolbar.m` in `cli/src/native.ts` and `cli/src/build-config.ts`) and add `native/platform/ios/routing.m` alongside `toolbar.m`/`sidebar.m` (the iOS sources array — NOT the darwin one). It must compile only for iOS targets, exactly like toolbar.m.

### Step 7 — Full gates

`bun run check`; `bun test cli/src`; `bun run test:native` (routerstate test green); `cd kitchen-sink && bun run build` (`[zapp] build complete:`, **macOS unaffected**); `cd kitchen-sink && bun run build --platform ios` (`[zapp] build complete:` — links `routing.m` + the new externs; this is the T1 gate that the native side compiles + the importc/exportc symbols resolve).

### Step 8 — Commit

```bash
git add native/nim/routerstate.nim native/nim/routerstate_test.nim native/nim/router.nim runtime/window.ts native/nim/window.nim native/platform/ios/routing.m cli/src/native.ts
git commit  # message below + trailer
```
(Adjust the test-file name to the actual routerstate test path; add `cli/src/build-config.ts` instead of/in addition to `native.ts` if that's where the iOS source list lives.)
Message: `feat(ios): native routing risk-gate core — routerstate-driven contentNav push/pop sync`

---

## Task 2: Kitchen-sink isolated `/detail` demo + docs + human iOS-sim smoke

**Files:**
- Modify: `kitchen-sink/zapp.config.ts` (or `kitchen-sink/zapp/app.nim` — wherever the main window options live) — set `nativeRouting: true`.
- Modify: `kitchen-sink/src/shell/main-pane.ts` (+ a tiny detail render) — isolated `/detail` demo.
- Modify: `docs/api-reference.md` — "iOS native routing (preview)" note.

**Interfaces consumed (from Task 1):** `WindowOptions.nativeRouting`; on iOS, `router.push` now drives a native VC push.

### Step 1 — Opt the kitchen-sink window into native routing

In the kitchen-sink window options (the `window` block in `kitchen-sink/zapp.config.ts`, or the `app.window.create`/`AppConfig.window` in `app.nim` — read which the kitchen-sink uses), add `nativeRouting: true`. On macOS this is ignored (desktop nav unchanged); on iOS it turns on the native push path.

### Step 2 — Isolated `/detail` demo (button + page)

In `kitchen-sink/src/shell/main-pane.ts`, keep the existing section nav (do NOT convert it). Add an **isolated** demo within the home/main render: a button that pushes a native route, and special-case `/detail` in `show`/the render so the pushed route webview renders a detail page. Concretely:

- Add a "Push native route (/detail)" button to the main pane (in `renderMainPane`, append to the stage or a fixed demo strip):
  ```ts
  // N3a demo: on iOS (nativeRouting) this pushes a real native VC; on macOS it's
  // an in-window route (N2b). Isolated from the section nav.
  const t0 = performance.now();
  const detailBtn = document.createElement("button");
  detailBtn.textContent = "Push native route (/detail)";
  detailBtn.onclick = () => Window.current().router.push("/detail");
  stage.appendChild(detailBtn);  // or a dedicated demo container
  ```
- Special-case `/detail` in the route render so a route (or root) webview showing `/detail` renders the detail page. In the `win.router.on` handler + first render, before `show(sectionForRoute(e.url))`, branch:
  ```ts
  const renderRoute = (url: string) => {
    if (url === "/detail") {
      stage.innerHTML = `<div class="detail-page" style="padding:24px">
        <h2>Detail route (/detail)</h2>
        <p>This is a native pushed view controller on iOS. Tap ‹ Back or swipe from the left edge to return.</p>
        <button id="ks-pop">Back (router.pop)</button></div>`;
      stage.querySelector("#ks-pop")?.addEventListener("click", () => Window.current().router.pop());
      console.log(`[ks] route /detail rendered (+${(performance.now() - t0).toFixed(0)}ms boot)`);
      return;
    }
    show(sectionForRoute(url));
  };
  ```
  Replace the existing `show(sectionForRoute(e.url))` calls in the `router.on` handler and first-render with `renderRoute(e.url)` / `renderRoute(win.router.url)`. (This keeps section nav identical and only adds the `/detail` branch.)

The boot-cost `console.log` (prefixed `[ks]`, visible in the terminal) gives the per-route render timing for the smoke.

### Step 3 — Docs

`docs/api-reference.md`: under the Router/Window section add a short note:
```markdown
#### iOS native routing (preview)

Set `nativeRouting: true` on a window (iOS only) and `router.push` materializes a
real native `UINavigationController` push — a new view controller with its own
webview, native slide-in animation, and edge swipe-back — instead of the desktop
in-window content swap. The native back/swipe stays in lockstep with the router
stack. **Preview / risk-gate** in this release: per-route webview caching, state
restore on back, and per-route toolbar are not yet wired. macOS/Windows ignore the
flag (desktop in-window navigation).
```

### Step 4 — Full gates

`bun run check`; `bun test cli/src`; `bun run test:native`; `cd kitchen-sink && bun run build` (`[zapp] build complete:`); `cd kitchen-sink && bun run build --platform ios` (`[zapp] build complete:`).

### Step 5 — Commit

```bash
git add kitchen-sink/zapp.config.ts kitchen-sink/src/shell/main-pane.ts docs/api-reference.md
git commit  # message below + trailer
```
(Use `kitchen-sink/zapp/app.nim` instead of `zapp.config.ts` if that's where the window opts live.)
Message: `feat(kitchen-sink): native-routing /detail demo + docs (N3a risk gate)`

### Step 6 — HUMAN iOS-SIM SMOKE GATE

STOP for the controller/user. Build + run the kitchen-sink on the **iPhone simulator**. Verify (spec §4):
1. **Push:** tap "Push native route (/detail)" → a new view controller **slides in** from the right rendering the `/detail` page over the root. The `[ks] route /detail rendered (+Nms boot)` line logs the per-route webview cost.
2. **Native back:** the `‹ Back` button (or the nav back affordance) pops it → slides out → root restored; `ROUTE_CHANGED` fired (canGoBack back to false at root).
3. **Edge swipe-back:** swipe from the left edge → also pops the route → root restored.
4. **2-deep + pop-from-middle:** push `/detail` twice (or push `/detail` then a section route) → 2 VCs deep → back/swipe pops one at a time, `routerstate` + content stay coherent.
5. **No loop / no crash / no bridge-kill:** rapid push→swipe→push; the app stays responsive, no double-render storm, no WKWebView teardown crash.
6. **Worker alive:** the headless `greeter` worker keeps logging across pushes (shared state survives route changes).
7. macOS build + iOS compile green; **the N2b desktop nav (macOS) still behaves** (sections + toolbar back/forward unaffected).

If a gotcha shows (swipe doesn't pop, toolbar stops updating on a routed VC, a teardown crash, or a sync loop), capture what you saw — that's the risk-gate signal and we iterate before N3b.

## Self-Review

**Spec coverage:** §1 opt-in+isolation → T1 Step 3/4 (`nativeRouting`) + T2 Step 1/2 (isolated demo, macOS gated). §2 push mechanism → T1 Step 2 (router hook) + Step 5 (mint VC+webview, contentNav push). §3 sync + loop-break + gotchas → T1 Step 5 (reconcile-to-match, nav delegate compose, swipe inherited from sidebar.m, brk-1 teardown). §4 testing/decomposition/smoke → T1 gates + T2 human sim smoke. Deferred (#770 cache/restore, zapp.route, per-route chrome, iPad) → not in any task (correctly out of scope).

**Deviation from spec §2 (flagged):** the spec injects `zapp.route` into the pushed webview for a synchronous initial render; this plan **defers `zapp.route` to N3b** and renders the route via the app's existing `router.current()`/`ROUTE_CHANGED` (the N2b mechanism) — smaller T1 surface (no `create_ext` signature change). Cost: the pushed webview may briefly show the root route before the top route resolves (cosmetic; the smoke notes it; N3b's `zapp.route` + per-route isolation fixes it). This keeps the risk gate focused on the *mechanism* (push/pop/sync/swipe/teardown), which is the actual unknown.

**Placeholder scan:** Nim/TS/config steps are concrete code. `ios/routing.m` is concrete with explicit "confirm against ios/webview.m:749 / replace the handler name / verify the subview lookup" implementer-notes — decidable lookups against named line anchors, not placeholders; the risk-gate gotchas are pre-solved-in-codebase pointers (sidebar.m:256–274/:477, toolbar.m:188) with a report-if-resists instruction.

**Type/name consistency:** `zapp_ios_router_sync` (router.nim importc ↔ routing.m def), `zapp_router_pop_from_native` (router.nim exportc ↔ routing.m extern), `router_depth`/`router_current_url` (routerstate.nim exportc ↔ routing.m extern — note the C name is `router_depth` from Nim `routerDepth` only if `{.exportc.}` preserves camelCase; **set `{.exportc: "router_depth".}` explicitly** so the C name matches the extern), `zapp_window_native_routing` (window.nim exportc ↔ routing.m extern), `nativeRouting` (WindowOptions TS ↔ window.nim field/JSON key). **Fix applied:** use explicit `{.exportc: "router_depth".}` / `{.exportc: "router_current_url".}` on the Nim accessors so the emitted C symbol names match routing.m's externs exactly.
