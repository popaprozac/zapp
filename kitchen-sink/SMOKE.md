# Kitchen Sink — Smoke Test Matrix

The authoritative manual-smoke surface. Two builds, run from `kitchen-sink/`:
- **zc** (default, the baseline): `bun run dev`
- **nim** (the migration target): `ZAPP_NATIVE_LANG=nim bun run dev`

**Goal: parity** — nim should match zc except the documented caveats below.

**Legend (fill the zc/nim cells as you smoke):** `✓` pass · `✗` fail · `—` n/a · `⚠️` known caveat (see notes). zc cells are pre-marked `✓` (cycle-1 was smoked); nim cells are `?` = needs your smoke (expected to pass unless noted).

## Known caveats on nim (NOT regressions — expected at this stage)
- **Home greet line shows `greet → [object Object]`** on nim (zc shows "Hello from Zapp!"). App **services** are Zen-C handlers in `app.zc` the Nim build can't run; nim registers only the skeleton `greet` (returns a JSON object). Service parity is a separate deferred milestone. Window title ("Kitchen Sink") + menu name ("kitchen-sink") DO match.
- **Inspector toggle may not reveal the inspector** on nim (tracked #460 — the toolbar's `toggleInspector` → `darwin_inspector_toggle` binding; the *sidebar* toggle works). The inspector pane itself mounts (collapsed).

---

## A. Shell boot (the headline — initial-window-from-config)
| Check | Expected | zc | nim |
|---|---|---|---|
| Launch chrome | Window boots as the shell: native sidebar (Home/Sidebar/Inspector/Toolbar/Popover/Multi-window), main pane, collapsed inspector, native toolbar | ✓ | ? |
| Window title | Title bar reads **"Kitchen Sink"** | ✓ | ? |
| App/menu name | Menu bar app menu + About/Quit read **"kitchen-sink"** (not "Zapp v2 (Nim)" / "Zapp Nim Skeleton") | ✓ | ? |
| Home greet | zc: "greet → Hello from Zapp!"  ·  nim: "greet → [object Object]" (⚠️ skeleton service, expected) | ✓ | ⚠️ |
| Nav | Clicking a sidebar row swaps main pane + inspector; **Home** returns to welcome | ✓ | ? |

## B. Sidebar section
| Check | Expected | zc | nim |
|---|---|---|---|
| Toggle | native sidebar hides/shows; toolbar sidebar button also toggles | ✓ | ? |
| Width 180 / 320 | sidebar resizes; inspector pane shows `width 180`/`320` | ✓ | ? |
| **Interaction (EMIT)** | clicking an item updates the main pane (cross-pane `Events.emit`, t:3 fix) | ✓ | ? |

## C. Inspector section
| Check | Expected | zc | nim |
|---|---|---|---|
| Toggle | trailing inspector hides/shows | ✓ | ⚠️ (#460) |
| Width 360 | inspector resizes; its own pane reads `width 360` | ✓ | ? |

## D. Toolbar section
| Check | Expected | zc | nim |
|---|---|---|---|
| Toggle Compose enabled | Compose item greys out / re-enables | ✓ | ? |
| Cycle filter | reopen Filter menu → checkmark moved | ✓ | ? |
| Remove / Attach | titlebar shrinks then grows back | ✓ | ? |

## E. Popover section
| Check | Expected | zc | nim |
|---|---|---|---|
| From button / toolbar | NSPopover with web content appears at the anchor | ✓ | ? |
| Counter | increments and survives hide/show | ✓ | ? |
| Emit → main pane | result line confirms cross-pane event | ✓ | ? |

## F. Multi-window section (WindowManager — now works on nim)
| Check | Expected | zc | nim |
|---|---|---|---|
| New window / small / vibrancy | a window opens; result logs its id (no longer "needs WindowManager") | ✓ | ? |
| **New window (sidebar shell)** | a 2nd full native-chrome window opens (sidebar + inspector) — chrome-on-nim | ✓ | ? |
| Sheets (page/form/bottom) | a sheet attaches to the shell window | ✓ | ? |

---

## Appendix — hello-world (nim), WindowManager core
`cd ../hello-world && ZAPP_NATIVE_LANG=nim bun run dev` (on-page buttons; the WM smoke vehicle):
| Check | Expected | nim |
|---|---|---|
| New Window | a 2nd window opens (`Window.create`) | ✓ (smoked 06-16) |
| New Window (sidebar) | window opens WITH native sidebar + toolbar chrome | ✓ (smoked 06-16) |
| Popover buttons | native web-content popover appears | ✓ (smoked 06-16) |
| Sidebar item click → main | main pane updates (t:3 EMIT) | ✓ (smoked 06-16) |
| Inspector toggle | reveals inspector | ⚠️ #460 (renders as labeled button, doesn't toggle) |

---

*Sections grow as cycles land (next: Workers + Sync). Each row should match zc↔nim except the ⚠️ caveats.*
