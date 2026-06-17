# Kitchen Sink — Smoke Checklist

The structured manual smoke surface (replaces ad-hoc clicking around hello-world).
Run `bun run dev` (zc — full features) from `kitchen-sink/`. The `nim ⏳` column
tracks `ZAPP_NATIVE_LANG=nim bun run dev`: native chrome lights up once the
WindowManager port lands; non-chrome works today.

## Shell
| Check | Expected | zc | nim |
|---|---|---|---|
| Launch | Window opens: native sidebar (left nav, **Home** active), main pane showing the Home welcome, collapsed inspector, native toolbar | ✓ | ⏳ |
| Greet | Home view shows "greet → Hello from Zapp!" (Services round-trip) | ✓ | ✓ |
| Nav | Clicking a sidebar row swaps the main pane + inspector; clicking **Home** returns to the welcome view | ✓ | ⏳ |

## Sidebar section
| Check | Expected | zc | nim |
|---|---|---|---|
| Toggle | native sidebar hides/shows; toolbar sidebar button also toggles | ✓ | ⏳ |
| Width 180 / 320 | sidebar resizes; inspector pane shows `width 180`/`320` | ✓ | ⏳ |

## Inspector section
| Check | Expected | zc | nim |
|---|---|---|---|
| Toggle | trailing inspector hides/shows | ✓ | ⏳ |
| Width 360 | inspector resizes; its own pane reads `width 360` | ✓ | ⏳ |

## Toolbar section
| Check | Expected | zc | nim |
|---|---|---|---|
| Toggle Compose enabled | Compose item greys out / re-enables | ✓ | ⏳ |
| Cycle filter | reopen Filter menu → checkmark moved | ✓ | ⏳ |
| Remove / Attach | titlebar shrinks then grows back | ✓ | ⏳ |

## Popover section
| Check | Expected | zc | nim |
|---|---|---|---|
| From button / toolbar | NSPopover with web content appears at the anchor | ✓ | ⏳ |
| Counter | increments and survives hide/show | ✓ | ⏳ |
| Emit → main pane | result line confirms cross-pane event | ✓ | ⏳ |

## Multi-window section
| Check | Expected | zc | nim |
|---|---|---|---|
| New window / small / vibrancy | a window opens; result logs its id | ✓ | ⏳ (shows "needs WindowManager") |
| Sheets (page/form/bottom) | a sheet attaches to the shell window | ✓ | ⏳ |
