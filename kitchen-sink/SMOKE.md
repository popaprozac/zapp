# Kitchen Sink — Smoke Test Matrix

The authoritative manual-smoke surface. Two builds, run from `kitchen-sink/`:
- **zc** (default, the baseline): `bun run dev`
- **nim** (the migration target): `ZAPP_NATIVE_LANG=nim bun run dev`

**Goal: parity** — nim should match zc except the documented caveats below.

**Legend (fill the zc/nim cells as you smoke):** `✓` pass · `✗` fail · `—` n/a · `⚠️` known caveat (see notes). zc cells are pre-marked `✓` (cycle-1 was smoked); nim cells are `?` = needs your smoke (expected to pass unless noted).

## Known caveats on nim (NOT regressions — expected at this stage)
- **Home greet line shows `greet → [object Object]`** on nim (zc shows "Hello from Zapp!"). App **services** are Zen-C handlers in `app.zc` the Nim build can't run; nim registers only the skeleton `greet` (returns a JSON object). Service parity is a separate deferred milestone. Window title ("Kitchen Sink") + menu name ("kitchen-sink") DO match. **Same root cause** affects the Workers section's "Invoke greet (from worker)" — the round-trip works on both builds, but the returned `greet` value is the skeleton object on nim vs the real string on zc.
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

## G. Workers section (headless zjs worker — the marquee differentiator)
Backed by the headless `greeter` worker (id `h-greeter`, engine zjs) declared in `zapp.config.ts` — it boots with the app and is what compiles the worker engine into the binary. Same `src/worker.ts` source runs on both builds.
| Check | Expected | zc | nim |
|---|---|---|---|
| Send ping | result shows `pong → {…}` (worker echoes over the Events bus, worker→webview fan-out) | ? | ? |
| Invoke greet (from worker) | result shows `service-result → {"result":…}` — worker called the native `greet` via Services.invokeSync (⚠️ value is skeleton object on nim, real string on zc; round-trip itself works on both) | ? | ⚠️ |
| Workers.list() | result lists `h-greeter` (engine `zjs`, name `greeter`) | ? | ? |

## H. Sync section (cross-context wait / notify — needs 2 windows)
Open a 2nd window first (Multi-window → **New window (sidebar shell)**), then drive wait/notify across the two.
| Check | Expected | zc | nim |
|---|---|---|---|
| Wait + Notify (cross-window) | click **Wait** in window A, **Notify "demo" (one)** in window B → A's result flips to `resolved → …` | ? | ? |
| notifyAll | click **Wait** in 2+ windows, then **Notify "demo" (all)** in any → every waiter resolves | ? | ? |
| Wait timeout | click **Wait** and don't notify → resolves with a timeout value after 10s (no hang) | ? | ? |

> Note: G/H cells are `?` on BOTH builds — these sections are new this cycle, so neither has been smoked yet (the zc path reuses the proven hello-world worker/sync APIs, so it's expected to pass).

## I. Dialogs section (host system integration)
Native file open/save + message dialogs. The native routes ship in both binaries (dialog.m + nim routeDialog), so it's a real parity surface. No permission block on kitchen-sink → ungated.
| Check | Expected | zc | nim |
|---|---|---|---|
| Open file | native open panel; result shows the absolute path (or "cancelled") | ? | ? |
| Save file | native save panel; result shows the chosen path | ? | ? |
| Message | native alert with OK/Cancel; result shows the button index | ? | ? |
| Reveal / Open last | after picking a file, reveals it in Finder / opens with the default app | ? | ? |

## J. Clipboard section
Read/write system clipboard (text + image). clipboard module is in both binaries.
| Check | Expected | zc | nim |
|---|---|---|---|
| Write / Read text | Write then Read round-trips the text | ? | ? |
| Has image / Read image | copy an image elsewhere → "has(image) → true" + "got N-byte PNG" | ? | ? |
| Clear | clipboard cleared (subsequent Read shows empty) | ? | ? |

## K. Notifications section
Native system notifications (notification.m + nim routeNotification). Dev runs inside the .app bundle so the notification center is available.
| Check | Expected | zc | nim |
|---|---|---|---|
| Request permission | result shows the permission status | ? | ? |
| Show | a system notification appears; result shows its id | ? | ? |
| Update / Remove last | the last notification updates in place / is removed | ? | ? |

> Note: I/J/K are new this cycle — `?` on both builds. All three are host features already ported to nim (B6 batch), so parity is expected.

## L. Screen section (displays — read-only)
Enumerate displays + geometry. Routes through `__screen:*` (explicit nim routes), so a real parity surface.
| Check | Expected | zc | nim |
|---|---|---|---|
| List displays | result lists each display name + WxH (primary marked) | ? | ? |
| Primary | result shows the primary display name + size + scale | ? | ? |
| Cursor point | result shows the mouse x,y + the display it's on (macOS; iOS returns 0,0) | ? | ? |

## M. Shortcuts section (global input)
Register/unregister a global accelerator (`CmdOrCtrl+Shift+K`). Routes through `__shortcuts:*` (explicit nim routes).
| Check | Expected | zc | nim |
|---|---|---|---|
| Register + fire | Register, switch to another app, press the combo → result shows "fired at …" | ? | ? |
| Is registered? | reports true after Register, false after Unregister | ? | ? |
| Unregister | combo no longer fires | ? | ? |

> Note: L/M are new this cycle — `?` on both builds; both have explicit `__screen:*` / `__shortcuts:*` nim routes, so parity is expected.

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

*Sections grow as cycles land: Workers + Sync → Dialogs + Clipboard + Notifications → Screen + Shortcuts. Each row should match zc↔nim except the ⚠️ caveats. Still to mirror from hello-world: Dock, Tray, Events, File Drop, Embedded Webview, and Theme (deferred — `App.getTheme()`'s initial value reads bootstrap config; needs a smoke to confirm nim seeds it, vs the live `THEME_CHANGED` event which is wired).*
