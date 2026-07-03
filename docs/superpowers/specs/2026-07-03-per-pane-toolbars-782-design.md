# Per-Pane Toolbars + Presentation Coupling — #782 / #781 / #783 (Design)

**Date:** 2026-07-03 · **Branch:** `feat/nim-native` (BASE `280e6a2`, immediately after #771 full close) · **Status:** user-approved
**Cycle:** one per-VC visibility FOUNDATION refactor + the per-pane chrome FEATURE built on it + two fixes the foundation enables (#781 presentation coupling, #783 single-window swipe-back). Subsumes #784 (its two residuals are fixed by the foundation).

## Guiding tenet

Zapp deviates from native platform UI defaults on purpose: it is a **desktop-web framework** — devs roll their own UI in HTML/CSS, and opt IN to native chrome piece by piece (memory `feedback_web_canvas_default_native_optin`). So the sidebar pane is **bar-less by default** (today's shipped fullbleed look, zero behavior change); configuring `title`/`toolbar` on a pane IS the opt-in that makes its bar appear (**config-implied**, not a boolean flag). This is the opposite of UIKit's "every column gets a populated bar" default — and that is intentional.

## Researched foundation (memory `reference_ios_navbar_visibility_per_vc`)

The clean-room spike (`spikes/ios-splitview-reference/`, the "zero custom code" native baseline #771 was measured against) proves the idiom empirically:
- Columns get bars by UIKit DEFAULT; the spike's sidebar/content VCs have ZERO visibility code.
- Only the chrome-less DETAIL route hides its OWN bar, in `DetailViewController.m:206-252`: `viewWillAppear` → `setNavigationBarHidden:YES animated:`; `viewWillDisappear` → inside `transitionCoordinator animateAlongsideTransition:` so the show rides the pop gesture and a CANCEL rolls it back in lockstep.

Zapp's CURRENT model drives visibility from the nav-controller DELEGATE (`ZappRouteNavDelegate` willShow/didShow) + hand-rolled compact-transition writes. That is against the grain and STRUCTURALLY leaves #784's two residuals: `willShow` misses the split-VC column un-nest (→ empty sidebar bar on return); `didShow` fires post-settle so a cancelled-swipe re-hide is grafted-on, not coordinator-coupled (→ instant vanish). Per-VC `viewWillAppear` fires on the un-nest AND is coordinator-coupled — it fixes both where the delegate cannot.

## Ground truth (exploration at HEAD `280e6a2`, file:line)

1. **Pane VCs are ONE class, role-tagged.** `ZappIOSPaneViewController` (`native/platform/ios/window.m:387-478`) hosts all three panes via `paneRole` (0 content, 1 sidebar, 3 inspector). Existing overrides: `viewSafeAreaInsetsDidChange`, `viewDidAppear:`, `viewWillTransitionToSize:`, `viewDidLayoutSubviews` — but **NO `viewWillAppear`/`viewWillDisappear`**. Per-VC visibility lands as ONE override branched on `paneRole`. `ZappRouteVC` (`routing.m:101-155`) is a distinct class, also with no `viewWillAppear`. The plain no-split window (`ZappIOSRootViewController`, `window.m:484-492`) is NOT nav-wrapped — bar ownership is vacuous there, set_items already no-ops (`toolbar.m:988-992`).
   - Sidebar VC is deliberately `hostSlot=−1` (`window.m:1042-1054`) to keep metrics hooks disarmed; the override uses the wired `windowPtr`, NOT hostSlot.
   - Navs: iPad `sbNav` (bar hidden, `sidebar.m:906-907`) + `ctNav` (bar visible, `:908-914`); iPhone combined nav via `zapp_ios_collapsed_nav` (`:405-414`); persistent `inspectorNav` (`window.m:1245-1246`, iOS-26 Inspector column `:1291-1295`).

2. **Seven visibility-writer sites the refactor retires** (two impure — halves re-homed, not deleted):
   - `zapp_ios_sidebar_apply_collapsed_bar` (`sidebar.m:463-488`) — ⚠️ ALSO stamps items (`:487`); stamp half re-homes.
   - didShow re-assert (`routing.m:442-446`) — enclosing `didShowViewController:` keeps depth-reconcile, iOS-26 gesture write, force-restamp, drop-retarget.
   - didCollapse priming (`sidebar.m:709-725`, only `:725` is the write) — enclosing keeps collapsedNav capture, pop re-arm, delegate install, sync-collapse emit, toolbar re-apply.
   - willShow write (`routing.m:333-346`) — ⚠️ metrics re-inject (`:339-345`) nested INSIDE; must re-fire from VC on bar toggle.
   - setItems attach primer (`toolbar.m:1071-1078`); remove() hide primers (`:1479-1482`, `:1512-1515` — ⚠️ the `--zapp-toolbar-height:0` inline JS at `:1523-1564` is justified BY the primer; re-sequence).
   - construction primers (`sidebar.m:907/914`, `window.m:977` — note `toolbar.m:1042`'s comment cites STALE line refs).

3. **Config entry:** `SidebarOptions` (`runtime/window.ts:244-285`, Nim `window.nim:126-137`) / `InspectorOptions` (`window.ts:294-317`, Nim `:139-149`) — NO toolbar/title today. Window toolbar travels create-time via `toolbarJson` (`window.ts:1893-1903` → Nim `parseToolbarJson` → `serializeToolbar` `window.nim:592-595`); per-route via T8 chrome JSON `{navbarHidden,title,toolbarJson}` (`router.nim:704-718` → `routing.m:568-592` → associated-object per-VC store `toolbar.m:1305-1330`). Sidebar/inspector travel to iOS as SCALAR accessors (`wopts_sidebar_*`, `window.nim:274-296`), not JSON — a new `wopts_sidebar_toolbar_json` string accessor follows the `toolbarJsonCache` pinning pattern (`window.nim:193-194`).

4. **normalizeToolbar seam:** `applyToolbarConventions` (`window.ts:907-943`) is the self-declared "single placement-resolution point … future per-pane placement config feeds overrides into this function." Only wire key that is pane-scoped today: `trackingSeparator.pane` (`:1004-1013`, Nim `:106`, serialize `:450`, darwin consume `darwin/toolbar.m:523-530`). Generalizing `pane` to all items reuses the ENTIRE wire.

5. **macOS = ONE NSToolbar, order-decides-region.** `NSTrackingSeparatorToolbarItem` (`darwin/toolbar.m:247-250`) makes items ordered BEFORE the sidebar separator render over the sidebar — native semantic, already works. Gap: `applyToolbarConventions` never puts app items there (`:942 [...prefix,...rest,...suffix]`). So #782 macOS is a `normalizeToolbar` ORDER change — **zero darwin/toolbar.m**. No macOS per-pane TITLE concept (documented v1 no-op).

6. **#781:** `zapp_ios_apply_presentation` (`sidebar.m:172-202`) sets split-GLOBAL `preferredSplitBehavior`/`preferredDisplayMode` + `showColumn:Primary`; re-applied on EVERY rotation/trait change (`sidebar.m:637/645/665`), register (`:942`), toggle-expand (`:1270`), explicit set (`:1443-1455`) — so a collapsed inspector reappears on rotation. No line names Inspector, but all act on the split hosting it, and no call site captures/restores `isShowingColumn:Inspector`. Inspector collapsed truth: live `[split isShowingColumn:UISplitViewControllerColumnInspector]` (`inspector.m:613`) + `lastCollapsedEmit` dedupe (`:116`, didHide silence `:369`). **No per-column displayMode/behavior API exists in-code** — presentation is split-global by UIKit design.

7. **iOS-26 gesture guardrail:** `routing.m:457-459` — `nav.interactiveContentPopGestureRecognizer.enabled = shownRouteWantsBarHidden` in didShow. INVARIANT: written only at SETTLED moments (didShow fires on commit AND cancel), never mid-transition (toggling `.enabled` on an in-flight interactive pop cancels it — #771 T7 I1 lesson). Stays in didShow even after visibility moves to viewWillAppear.

8. **#783:** `windowId <= 0` guard (`routing.m:545-548`) — main window is id 0, so `zapp_ios_sidebar_rearm_pop` (`sidebar.m:435-436`) + didCollapse install (`:707-708`) silently no-op; only push installs unguarded (`:557`). Net: single-window apps have NO willShow owner until first push. Per-VC `viewWillAppear` needs no install → asymmetry evaporates. Residual: delegate-owned swipe-back auto-restore on chrome-less collapsed window — targeted guard fix in Phase 1 (`< 0` or key off resolved window; implementer confirms install-order interaction).

## Architecture — three phases, two human gates

### Phase 1 — Per-VC visibility FOUNDATION (RISK GATE; Opus-implemented)
Add `viewWillAppear`/`viewWillDisappear` to `ZappIOSPaneViewController` (branched on `paneRole`: sidebar → hidden unless configured; content → want-state rule; inspector → its own rule) and `ZappRouteVC` (reads `navbarHidden`; spike's `animateAlongsideTransition` dance for cancelled swipes). Read the EXISTING `zapp_route_bar_want_state` predicate — do NOT reimplement the rule. Surgically retire the seven writer sites; re-home the two impure halves (apply_collapsed_bar's stamp → stamp path; willShow's metrics re-inject → VC on bar toggle). KEEP in delegate: item stamping, pop-gesture ownership, depth reconciliation, the iOS-26 gesture toggle (didShow). Fold #783's guard fix here (the asymmetry it addresses is the same install-order issue this refactor removes).

**GATE G1 (human, iPhone + iPad):** the full #771 G2 matrix RE-RUN (foundation holds the line — per-route chrome, hidden-navbar swipe-back, iPad edge-pins, toolbar transitions) + #784 residuals now PASS (empty sidebar bar gone; cancelled-swipe animates out) + #783 single-window launch swipe-back works. A red G1 STOPS the cycle — the foundation is the go/no-go.

### Phase 2 — Per-pane chrome (the FEATURE; Sonnet-implemented from complete briefs)
- **Authoring:** `sidebar: { title?, toolbar? }`, `inspector: { title?, toolbar? }` (TS + Nim symmetric) — pure sugar desugaring into the ONE window toolbar def with each item tagged `pane:"sidebar"|"inspector"`. Actions register in the same `${windowId}:${id}` map (unchanged click routing).
- **normalizeToolbar:** `applyToolbarConventions` gains pane-aware bucketing — pane-tagged items ordered into their pane's region; untagged stay in content region (today's behavior). TDD.
- **Wire:** new `wopts_sidebar_toolbar_json`/`wopts_sidebar_title` (+inspector) string accessors, `windowOptsApplyJson` parse, passed to register. Nim parity tests.
- **iOS:** stamp pane title+items onto the sidebar/inspector column nav's `navigationItem`; Phase-1 `viewWillAppear` shows the bar iff the pane has content. Toggle placement COOPERATES with the split-VC's native display-mode button (sidebar-toggle lives in the sidebar bar when expanded, migrates to content when collapsed — UIKit-native once the sidebar owns a real bar).
- **macOS:** pane-tagged items order into the sidebar region relative to the existing trackingSeparator anchors — `normalizeToolbar` only, zero darwin/toolbar.m. `title` = documented v1 no-op (apps own the sidebar header in HTML).
- **Runtime:** `win.sidebar.setTitle(s)` / `win.inspector.setTitle(s)` only (one action each; contextual titles). Full item mutation is the ticketed follow-up.

**GATE G2 (human, combined):** sidebar/inspector own populated bars + titles on iPad; toggle placement correct; macOS sidebar-region ordering; #771 regression clean; macOS untouched beyond normalizeToolbar.

### Phase 3 — #781 + docs (Sonnet; folds into G2)
Wrap `zapp_ios_apply_presentation`: capture `isShowingColumn:Inspector` before the write, restore after (didHide dedupe keeps it emit-silent) — covers all five call sites incl. rotation. Document `preferredSplitBehavior`/`preferredDisplayMode` as split-GLOBAL (sidebar overlay carries the inspector by UIKit design; no per-column API).

## Testing & gates
TDD: T2 pane bucketing round-trips (`runtime/window.test.ts`), T3 Nim serialize/parse parity. iOS parity gate (`bun test cli/src/ios-platform-parity.test.ts`) stays green. Native tasks: iOS-sim + macOS build gates (`[zapp] build complete:` + fresh mtime). NO iOS-sim in-session — human runs G1/G2.

## Model policy (this cycle — token-conscious per user)
- **Opus 4.8 (1M):** orchestrator + T1 (the risk-gate foundation refactor, investigation-shaped native restructure) + ALL task reviews + final whole-branch review.
- **Sonnet 5:** T2–T7 implementers, from briefs carrying complete code. Hard **BLOCK-don't-improvise** rule — a Sonnet implementer that hits a wrong premise escalates, never guesses.
- This cycle is the concrete trial of Sonnet-from-complete-brief on native work (T4 especially) — watch the Changes-needed rate as the read.

## Constraints (binding, unchanged from #771)
Branch `feat/nim-native`, banked in place, NO worktree/amend/merge-without-ask; per-file `git add` only; pre-existing unrelated WIP stays UNSTAGED; commit trailer EXACTLY `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` then `Claude-Session: https://claude.ai/code/session_01DZ9M515fEUqt9EE2oFDyyv`; always Bun; macOS must NOT regress (darwin/* changes ONLY the normalizeToolbar consumption in T2/T5 — NO darwin/toolbar.m; verified per task); iOS parity gate green; SDD execution, ledger `.superpowers/sdd/progress.md`.

## Out of scope (ticketed)
Full runtime pane-toolbar mutation `win.sidebar.toolbar.setItems/updateItem/remove` (follow-up); macOS sidebar-title NSToolbar item; #780 kitchen-sink route-UX (sidebar active-state / per-section memory).
