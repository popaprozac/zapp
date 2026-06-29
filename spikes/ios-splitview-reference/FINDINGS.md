# FINDINGS — ios-splitview-reference Phase 1

## Observe List

### iPhone (collapsed)

- [ ] (a) App starts on the **Sidebar** (Sections list) — not the Content VC.
- [ ] (b) Tap a section → Content slides in with a **back button** to the Sidebar.
- [ ] (c) **Edge-swipe from the left pops back to the Sidebar** — zero custom code.
- [ ] (d) "Push detail →" pushes Detail with a **back button** to Content.
- [ ] (e) **Edge-swipe pops Detail** back to Content — zero custom code.
- [ ] (f) Toolbar items are **correct per screen** (Sidebar: Compose; Content: Share+Filter; Detail: Trash) with no duplication and no stale items across push/pop.

### iPad (expanded)

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
