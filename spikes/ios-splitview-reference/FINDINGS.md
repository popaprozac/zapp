# FINDINGS — ios-splitview-reference Phase 1

## Observe List

### iPhone (collapsed)

> **PASS** — iPhone (collapsed): idiomatic UIKit gave sidebar-first collapse, native back button,
> edge-swipe-back, and correct per-VC toolbar (compose / filter+share / trash — no duplication,
> no stale) with ZERO custom code.

- [x] (a) App starts on the **Sidebar** (Sections list) — not the Content VC.
- [x] (b) Tap a section → Content slides in with a **back button** to the Sidebar.
- [x] (c) **Edge-swipe from the left pops back to the Sidebar** — zero custom code.
- [x] (d) "Push detail →" pushes Detail with a **back button** to Content.
- [x] (e) **Edge-swipe pops Detail** back to Content — zero custom code.
- [x] (f) Toolbar items are **correct per screen** (Sidebar: Compose; Content: Share+Filter; Detail: Trash) with no duplication and no stale items across push/pop.

### iPad (expanded)

> **NOT YET TESTED** — iPad: first run was compact (iPhone-compat mode); re-test after the
> `UIDeviceFamily=[1,2]` universal fix to exercise the expanded side-by-side split.

- [ ] (g) Sidebar + Content appear **side-by-side** on launch.
- [ ] (h) Tapping a section updates the Content column label in place; sidebar stays.
- [ ] (i) "Push detail →" pushes within the Content column; sidebar stays visible.
- [ ] (j) Back button + toolbar items are correct in the Content column after push/pop.

---

## Verdict

<!-- Fill in after running the observe list on both simulators. -->

**Overall:** (PASS / PARTIAL / FAIL)

**UIKit free behaviours confirmed:**

**Gaps / surprises:**

**Implication for Zapp:**
