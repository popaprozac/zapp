# iOS app-icon pipeline (#285) — design

**Date:** 2026-06-04
**Branch:** `feat/ios-app-icon`
**Surfaced by:** the app icon not appearing on iOS (it works on macOS). Diagnosis: the iOS icon pipeline is entirely absent — `resolveAppIconPath` only checks `build/macos/`; `icon.ts`'s PNG path emits macOS asset-catalog idioms + `actool --platform macosx`; `writeIOSDevPlist` writes no icon keys; and nothing compiles/copies an `Assets.car` into `bin/ios/<app>.app`. `IOSConfig.icon` exists in config (and its doc *claims* `build/ios/icon.png` works) but is never wired.

## Decisions (locked during brainstorming)

- **Q1 — source:** PNG-preferring chain with macOS reuse; **skip + warn** if only a non-PNG source exists (no fragile `.icns` extraction — future work).
- **Q2 — catalog shape:** single 1024² universal-iOS entry; `actool` downscales (modern Xcode-14+ form, fine on the iOS 15 floor).
- **Q3 — targets:** both `ios-simulator` and `ios-device` (the only difference is the `actool --platform` string).

## Scope

CLI-side only (`cli/src/`). No Zen-C / runtime / native `.m` changes. macOS icon path untouched.

## 1. Source resolution (`cli/src/paths.ts`)

New focused helper, returning a **PNG path or `""`** (iOS asset catalogs require a PNG source):

```ts
export function resolveIOSIconPng(root: string, config: { ios?: { icon?: string }; macos?: { icon?: string } }): string
```

Precedence (first existing `.png` wins):
1. `config.ios?.icon` — only if it resolves to an existing `.png`.
2. `build/ios/icon.png`
3. `build/icon.png` *(documented in `IOSConfig.icon`'s JSDoc)*
4. `config.macos?.icon` — only if it's an existing `.png` (reuse the one app icon).
5. `build/macos/icon.png`
6. Framework default `assets/zapp.png` (via `resolveAssetsDir()`).

Returns `""` when no `.png` is found (e.g. a project whose only icon is `.icns`/`.icon`/`.iconset`). The existing macOS `resolveAppIconPath` is **unchanged**.

## 2. iOS asset catalog (`cli/src/icon.ts`)

New `buildIOSAssetCatalog(pngPath, tempDir, target)` — a **separate** function from the macOS `buildAssetCatalog` (it has no `idiom:"mac"` entries and no `.icns` fallback to entangle):

1. Write `Assets.xcassets/AppIcon.appiconset/Contents.json` with a single image:
   ```json
   { "images": [ { "filename": "icon_1024x1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024" } ],
     "info": { "author": "xcode", "version": 1 } }
   ```
   plus the root `Assets.xcassets/Contents.json` (`{ info: { author: "xcode", version: 1 } }`).
2. Copy the source PNG to `icon_1024x1024.png`.
3. Compile:
   ```
   xcrun actool <xcassets> --compile <out> \
     --platform <iphonesimulator|iphoneos> \
     --minimum-deployment-target <ios min> \
     --app-icon AppIcon \
     --output-partial-info-plist <out>/partial.plist
   ```
   where the platform is derived from `target` (`ios-simulator` → `iphonesimulator`, `ios-device` → `iphoneos`) and the min-deployment from `config.ios?.minimumSystemVersion ?? "15.0"`.
4. Collect `Assets.car`. Return an `IconResult` reusing the existing type:
   `{ type: "assetcatalog", files: [{ src: <Assets.car>, dest: "Assets.car" }], plistKey: "CFBundleIconName", plistValue: "AppIcon" }`.

If `actool` fails or produces no `Assets.car`, log the stderr (`[zapp] actool …`) and treat as "no icon" (return null / throw caught by the caller → skip + warn), rather than crashing the build.

## 3. Wire into the iOS build (`cli/src/zapp-cli.ts`)

New shared helper used by **both** the iOS dev (~line 347) and build (~line 575) paths:

```ts
async function prepareIOSIcon(root, config, target, appBundle, tempDir): Promise<string | null>
```
- Resolve the PNG via `resolveIOSIconPng` (§1). If `""` → `clog`/log `[zapp] no PNG app icon for iOS (looked for ios.icon / build/ios/icon.png / …) — skipping icon` and return `null`.
- Else build the catalog (§2), copy `Assets.car` into the `.app` **root** (iOS places it at the bundle root, not `Contents/Resources/`), and return `"AppIcon"`.

`writeIOSDevPlist` gains an optional `iconName?: string`; when set it emits `<key>CFBundleIconName</key><string>AppIcon</string>` into the Info.plist.

**Order** in each iOS path: the `.app` dir + binary already exist → call `prepareIOSIcon` (copies `Assets.car`) → `writeIOSDevPlist({ …, iconName })` (writes the plist with the icon key) → the existing ad-hoc re-sign (binds the plist + car into the bundle). A `tempDir` under `.zapp/` (or the existing temp the build uses) holds the intermediate xcassets/actool output and is cleaned up.

## 4. Verification

- **`bun test`** (`cli/src/`, pure-TS): `resolveIOSIconPng` precedence — `ios.icon` PNG wins; falls through `build/ios/icon.png` → `build/icon.png` → macOS PNG → framework default; a non-PNG-only project returns `""`; a non-`.png` `config.ios.icon` is ignored. (Mirrors the `resolveNative`/`config.test.ts` style.)
- **Builds:** macOS `bun run build` → `[zapp] build complete:` (CLI-only change, must not regress); `bun run build --platform ios-simulator` → `[zapp] build complete:`.
- **Inspect (the iOS gate short of a running device):**
  - `plutil -p bin/ios/<name>.app/Info.plist | grep -i icon` → `CFBundleIconName = "AppIcon"`.
  - `ls bin/ios/<name>.app/Assets.car` exists.
  - `assetutil --info bin/ios/<name>.app/Assets.car` lists the `AppIcon` image.
- **Functional** (icon visible on the Home screen / app switcher): requires installing on the Simulator or a device — **manual**, noted for the human smoke.

## Non-goals

- **PNG extraction** from `.icns`/`.icon`/`.iconset` for iOS (Q1: skip + warn; a future enhancement via `sips`/`iconutil` if a real project needs it).
- **Legacy multi-size** asset-catalog matrix (Q2: single 1024²).
- **iOS 18 dark / tinted icon variants**, alternate icons, or a launch-screen/storyboard.
- **Any change to the macOS icon path** (`resolveAppIconPath`, `buildAssetCatalog`, `createDevBundle`).

## Related

- [[reference_ios_symbol_parity_gate]] / [[feedback_verify_native_build]] — the ios-simulator build is part of the verification (though this is a CLI change, not native).
- [[project_ios_path]] — iOS strategy; the icon pipeline is a packaging gap on that path.
- [[project_packaging]] — packaging prerequisites (icons, notifications, …).
- [[project_upstream_from_zim]] — prior alpha that wired the macOS icon pipeline this mirrors.
