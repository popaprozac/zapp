# Auto-update — path decision

**Status:** Decided. Implementation paused; pick up per Tier 2 of [the competitive plan](../plan.md) when a real customer asks, when shipping a versioned alpha to external testers, or when the next clear gap-priority window opens.

**TL;DR:** Hand-rolled, Tauri / Electrobun-shaped. **Not Sparkle.** ~430 LOC across Zen-C + router + runtime + CLI. Static `latest.json` manifest. Notarization as trust root. Cross-platform-ready by construction.

---

## Why this doc exists

Auto-update was the highest-severity polish gap in our zero-native competitive teardown ([plan](../plan.md), T1.4): table-stakes for any 2025 desktop app distributed outside the Mac App Store. Tauri ships an updater plugin, Electrobun has one built-in, Electron has Squirrel/electron-updater, zero-native has nothing yet.

We deferred the *path*, not the *goal*. This doc commits to a path so Tier 2 implementation can be scoped + planned against it.

## The three candidates

| | **Sparkle** | **Tauri-style (chosen)** | **Roll-our-own (greenfield)** |
|---|---|---|---|
| Binary bloat | +5–6 MB framework | none (~430 LOC) | none |
| Cross-platform | macOS only | macOS / Win / Linux from day one | macOS / Win / Linux from day one |
| Trust root | Sparkle EdDSA signature | macOS notarization (already shipped) | TBD — likely notarization + SHA |
| Manifest | Sparkle appcast XML | Static `latest.json` on any CDN | Custom |
| Update download | Sparkle handles | We own; HTTP + SHA-256 verify | We own; whatever we design |
| Apply pattern | Sparkle relauncher | `rename`-on-running-bundle + detached relaunch | TBD |
| Key management ops burden | EdDSA private key in your login Keychain — lose it = stranded users | Already-shipped notarization workflow | TBD |
| Net LOC we own | ~50 (config wiring + plumbing) | ~430 across the stack | 600–1000+ |
| Ecosystem familiarity | High (every macOS OSS app) | Medium (Tauri / Electrobun) | None |

## Why not Sparkle

Sparkle is the macOS-standard updater framework, and ten years ago it would have been the obvious answer. In 2025 / 2026 it's the wrong fit for **this** codebase for four reasons:

1. **EdDSA-signed feeds are redundant against notarization.** Sparkle's biggest selling point is feed signing: the EdDSA key prevents an attacker who controls the update URL from pushing a malicious bundle. But Zapp **already** notarizes every release (G9, shipped alpha.46) — and macOS verifies the new bundle's notarization on every launch automatically. To defeat the notarization gate, an attacker needs to (a) MITM HTTPS *and* (b) produce a notarized impostor binary — which requires stealing the Developer ID cert. If that's the threat model, no amount of EdDSA helps; the game is already over. The second signature layer adds operational complexity (the EdDSA private key in your login Keychain, which if lost strands every existing user forever) for no marginal security against any realistic adversary.

2. **5–6 MB of framework bloat is ~80% inflation against our ~7 MB baseline.** Zapp's headline is "445 KB binary, 7 MB packaged" — adding Sparkle nearly doubles the packaged size. That's a positioning hit we're not willing to take for redundant signing.

3. **Sparkle is macOS-only.** Zapp's roadmap covers iOS (shipping) + Windows (T2.C) + Linux (T3 / much later). Sparkle is a dead end for cross-platform unification — we'd need a parallel implementation per platform anyway. The Tauri-style approach uses the same `latest.json` shape across all three with a thin per-platform apply-step.

4. **Real ops burden, no real win.** Self-explanatory once you've thought about (1).

We document Sparkle as the **opt-in escape hatch** if a wedge customer specifically needs Sparkle-shaped UX (the macOS-native "Check for Updates…" menu item with a Sparkle dialog), but it's not the default path.

## Why not greenfield roll-our-own

Tempting because we control everything, but:

1. The Tauri / Electrobun teams already paid the design tax. Their manifest shape, trust model, and apply-step have been load-bearing in production for years. Re-deriving means re-discovering the same edge cases (network failures mid-download, partial-file corruption, `.app` rename semantics, app-translocation gotchas, sandbox-on-launch interactions).

2. Each design decision in greenfield is another commit to maintain. ~430 LOC vs. 600–1000+ LOC is not a small delta when this is a tier-1-stability surface.

3. Nothing in zero-native, Tauri, Electrobun, or the wider ecosystem makes greenfield interesting *as a differentiator*. Auto-update is plumbing. Win by shipping it, not by reinventing it.

## What we ship (the chosen path)

**Tauri-style minimal updater, ~430 LOC across the stack.**

### Manifest (`latest.json`)

Static JSON at a configurable URL. Hosted on S3 / CDN / GitHub Releases — no infrastructure to maintain.

```json
{
  "version": "1.2.0",
  "notes": "Bug fixes and performance improvements.",
  "pub_date": "2026-05-15T18:00:00Z",
  "platforms": {
    "darwin-aarch64": {
      "url": "https://releases.example.com/MyApp-1.2.0-arm64.zip",
      "sha256": "<hex>",
      "size": 7821342
    },
    "darwin-x86_64":  { "url": "...", "sha256": "...", "size": 0 },
    "windows-x86_64": { "url": "...", "sha256": "...", "size": 0 }
  }
}
```

### Trust model

- **Notarization** on each artifact (already in `cli/src/notarize.ts`). macOS verifies on launch — that's the primary integrity gate.
- **SHA-256** in `latest.json` for corruption detection during download (~10 LOC of verify code).
- HTTPS for transport (the manifest fetch).

That's it. No second-layer signing. No private keys in user Keychains.

### Native (Zen-C, ~250 LOC)

1. Fetch `latest.json` from the configured URL.
2. Compare `version` against the running app's `CFBundleShortVersionString`. If newer → "update available."
3. On user "install" click: download `url` to a staging path under `~/Library/Application Support/<bundle-id>/updates/`.
4. SHA-256 verify the downloaded archive.
5. Extract to staging dir.
6. Rename the running `.app` to a backup name, rename staging into place. **macOS allows `rename` of a running `.app` because file handles are inode-based** — no relauncher helper needed.
7. Detached relaunch (`open -n /Applications/<App>.app`), parent exits, child takes over.
8. On next boot, the running app cleans up the backup directory.

### Router (~40 LOC)

Three methods in the bridge:

- `__update:check` → returns `{ available: boolean, version?: string, notes?: string }`
- `__update:download` → kicks the download; emits `update:progress` events
- `__update:install` → triggers the rename + relaunch flow

### Runtime (~80 LOC)

```ts
import { Updater } from "@zappdev/runtime";

const update = await Updater.check();
if (update.available) {
  console.log(`v${update.version} available: ${update.notes}`);
  await Updater.download((p) => console.log(`${p.percent}% (${p.bytes}/${p.total})`));
  await Updater.installAndRestart();
}
```

### CLI (~60 LOC)

```bash
zapp release          # runs package --notarize, computes SHA-256, prints latest.json
zapp release --upload s3://my-bucket/releases   # v2; uploads + updates manifest in-place
```

### App-install location decision

Two viable models, **both work** under the chosen approach:

1. **`/Applications`** *(Tauri's path, recommended default)* — familiar to users; one `osascript "with administrator privileges"` prompt during update for the `mv -f`. The prompt is standard macOS UX.
2. **`~/Library/Application Support/<bundle-id>/<channel>/`** *(Electrobun's path)* — no admin prompt; but the install location is non-standard, so the user-facing extraction step feels weird. Good for menu-bar-only apps where the bundle is invisible after first launch.

**Recommend: ship #1 as the default; expose #2 via a `macos.installLocation: "user" | "system"` config flag for tray-only apps.**

## Deferred (not in scope for Tier 2 v1)

- **Delta updates** (bsdiff / zstd patch chains). Adds ~500 LOC. Add only when telemetry shows full-bundle bandwidth is a real complaint.
- **Channels** (stable / beta / canary). Filename prefix in `latest.json` URL (Electrobun-style). ~30 LOC follow-up.
- **Phased rollouts** (probabilistic enablement per cohort). Pure server-side — no client code change. Decide in `latest.json` generation.
- **Resume-on-network-fail**. HTTP `Range` requests. ~50 LOC follow-up.
- **Sparkle opt-in path** for customers who specifically need Sparkle UX. Revisit if it materializes.

## Tier 2 implementation sketch

When this lands, the work breaks down roughly as:

| Layer | LOC | Effort | Notes |
|---|---|---|---|
| `cli/src/config.ts` — add `macos.autoUpdate: { feedUrl, installLocation? }` | ~10 | <1 hr | Type extension only |
| `cli/src/release.ts` *(new)* — `zapp release` command | ~60 | 1 day | Reuses `cli/src/notarize.ts` |
| `native/update/update.zc` *(new)* — fetch / verify / apply | ~250 | 2 days | macOS first; Win/Linux later |
| `native/app/router.zc` — three new `__update:*` methods | ~40 | 0.5 day | Mirrors existing patterns |
| `runtime/updater.ts` *(new)* — typed JS API | ~80 | 0.5 day | `Updater.check / download / installAndRestart` |
| `docs/patterns.md` — "Auto-update" section | — | 0.5 day | Example app showing the full flow |

**Total: ~3 days of focused work + 1 day docs/QA.** Net cross-platform extension (Windows ZIP-update + Linux AppImage handling) is another ~150 LOC each, in T2.C and beyond.

## References

- Tauri v2 updater plugin: https://github.com/tauri-apps/plugins-workspace/tree/v2/plugins/updater (most direct analog)
- Electrobun `Updater.ts`: https://github.com/blackboardsh/electrobun/blob/main/package/src/bun/core/Updater.ts
- Apple QA1827 (legacy; mostly subsumed by notarization): https://developer.apple.com/library/archive/qa/qa1827/_index.html
- Sparkle (for the opt-in path later if needed): https://sparkle-project.org/documentation/

**See also:** [`/Users/zach/.claude/projects/-Users-zach-code-zapp/memory/project_gap_auto_update.md`](../../../.claude/projects/-Users-zach-code-zapp/memory/project_gap_auto_update.md) for the original spike record (2026-05-05) and earlier reasoning.
