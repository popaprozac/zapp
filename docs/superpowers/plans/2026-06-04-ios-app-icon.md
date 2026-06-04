# iOS App-Icon Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the app icon appear on iOS — resolve a 1024² PNG, compile an iOS asset catalog with `actool`, copy `Assets.car` into `bin/ios/<app>.app`, and add `CFBundleIconName: AppIcon` to the Info.plist.

**Architecture:** CLI-only (`cli/src/`). A new PNG resolver (`paths.ts`), a separate iOS asset-catalog builder (`icon.ts`), and a `prepareIOSIcon` orchestrator wired into both iOS build paths (`zapp-cli.ts`) before `writeIOSDevPlist`. The macOS icon path is untouched.

**Tech Stack:** TypeScript, Bun (`bun:test`, `Bun.spawn`), Xcode `xcrun actool`.

**Branch:** `feat/ios-app-icon` (created, spec committed).

**Spec:** `docs/superpowers/specs/2026-06-04-ios-app-icon-design.md`

**Conventions:**
- Stage ONLY the files each task names. Never `git add -A`. Never stage `vendor/bare`, `vendor/txiki.js`, `native/worker/engines/zjs-cross-eval-test.c`, `hello-world/src/main.ts`, `hello-world/zapp.config.ts`.
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Build success = LAST line `[zapp] build complete:`. macOS: `cd hello-world && bun run build 2>&1 | tail -1`. iOS: `cd hello-world && bun run build --platform ios-simulator 2>&1 | tail -1`.
- Transient `bun test` `EMFILE`/`Cannot find module` = fd exhaustion; re-run in a fresh process (`ulimit -n 4096`).

---

## Task 1: `resolveIOSIconPng` (TDD)

**Files:**
- Modify: `cli/src/paths.ts`
- Create: `cli/src/paths.test.ts`

- [ ] **Step 1: Write the failing tests**

Create `cli/src/paths.test.ts`:
```ts
import { test, expect } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { resolveIOSIconPng } from "./paths";

function tmpRoot(): string { return mkdtempSync(path.join(tmpdir(), "zapp-iosicon-")); }
function touch(p: string) { mkdirSync(path.dirname(p), { recursive: true }); writeFileSync(p, "x"); }

test("resolveIOSIconPng: a .png config.ios.icon wins", () => {
  const root = tmpRoot();
  touch(path.join(root, "myicon.png"));
  touch(path.join(root, "build", "ios", "icon.png"));
  expect(resolveIOSIconPng(root, { ios: { icon: "myicon.png" } })).toBe(path.join(root, "myicon.png"));
});

test("resolveIOSIconPng: build/ios/icon.png is next", () => {
  const root = tmpRoot();
  touch(path.join(root, "build", "ios", "icon.png"));
  touch(path.join(root, "build", "icon.png"));
  expect(resolveIOSIconPng(root, {})).toBe(path.join(root, "build", "ios", "icon.png"));
});

test("resolveIOSIconPng: build/icon.png is next", () => {
  const root = tmpRoot();
  touch(path.join(root, "build", "icon.png"));
  touch(path.join(root, "build", "macos", "icon.png"));
  expect(resolveIOSIconPng(root, {})).toBe(path.join(root, "build", "icon.png"));
});

test("resolveIOSIconPng: reuses a macOS .png", () => {
  const root = tmpRoot();
  touch(path.join(root, "build", "macos", "icon.png"));
  expect(resolveIOSIconPng(root, {})).toBe(path.join(root, "build", "macos", "icon.png"));
});

test("resolveIOSIconPng: a non-.png config.ios.icon is ignored and falls through", () => {
  const root = tmpRoot();
  touch(path.join(root, "logo.icns"));
  touch(path.join(root, "build", "macos", "icon.png"));
  expect(resolveIOSIconPng(root, { ios: { icon: "logo.icns" } })).toBe(path.join(root, "build", "macos", "icon.png"));
});
```

- [ ] **Step 2: Run, verify fail**

Run: `cd /Users/zach/code/zapp && bun test ./cli/src/paths.test.ts`
Expected: FAIL — `resolveIOSIconPng` is not exported.

- [ ] **Step 3: Implement `resolveIOSIconPng`**

In `cli/src/paths.ts`, add (after `resolveAppIconPath`; `existsSync` and `resolveAssetsDir` already exist in this file):
```ts
/**
 * Resolve a 1024×1024 PNG source for the iOS app icon. iOS asset catalogs
 * require a PNG, so non-PNG sources (.icns/.icon/.iconset) are skipped.
 * Precedence: config.ios.icon (.png) → build/ios/icon.png → build/icon.png →
 * config.macos.icon (.png, reuse) → build/macos/icon.png → framework zapp.png.
 * Returns "" if no PNG is found.
 */
export function resolveIOSIconPng(
  root: string,
  config: { ios?: { icon?: string }; macos?: { icon?: string } },
): string {
  const absExistsPng = (p: string): string | "" => {
    const abs = path.isAbsolute(p) ? p : path.resolve(root, p);
    return abs.toLowerCase().endsWith(".png") && existsSync(abs) ? abs : "";
  };

  // 1. config.ios.icon (must be a .png)
  if (config.ios?.icon) { const p = absExistsPng(config.ios.icon); if (p) return p; }
  // 2. build/ios/icon.png
  const buildIos = path.join(root, "build", "ios", "icon.png");
  if (existsSync(buildIos)) return buildIos;
  // 3. build/icon.png
  const buildRoot = path.join(root, "build", "icon.png");
  if (existsSync(buildRoot)) return buildRoot;
  // 4. config.macos.icon (reuse if it's a .png)
  if (config.macos?.icon) { const p = absExistsPng(config.macos.icon); if (p) return p; }
  // 5. build/macos/icon.png
  const buildMac = path.join(root, "build", "macos", "icon.png");
  if (existsSync(buildMac)) return buildMac;
  // 6. framework default
  const frameworkAssets = resolveAssetsDir();
  if (frameworkAssets) {
    const def = path.join(frameworkAssets, "zapp.png");
    if (existsSync(def)) return def;
  }
  return "";
}
```

- [ ] **Step 4: Run, verify pass**

Run: `cd /Users/zach/code/zapp && bun test ./cli/src/paths.test.ts`
Expected: 5 pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/paths.ts cli/src/paths.test.ts
git commit -m "$(cat <<'EOF'
feat(cli): resolveIOSIconPng — PNG source chain for the iOS app icon

ios.icon → build/ios/icon.png → build/icon.png → macos .png (reuse) →
build/macos/icon.png → framework zapp.png; returns "" if no PNG. bun-tested.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `buildIOSAssetCatalog` (icon.ts)

**Files:**
- Modify: `cli/src/icon.ts`

(No unit test — it spawns `actool`, which needs the Xcode toolchain; it's exercised by the iOS build in Task 3.)

- [ ] **Step 1: Add `buildIOSAssetCatalog`**

In `cli/src/icon.ts` (it already imports `path`, `mkdir`, `existsSync`, and defines `IconResult`), add an exported function (e.g. after `buildAssetCatalog`):
```ts
/**
 * Build + compile an iOS app-icon asset catalog from a single 1024² PNG.
 * Modern single-size form (idiom "universal", platform "ios"); actool
 * downscales. Returns an IconResult (Assets.car + CFBundleIconName), or
 * null if actool fails / produces no Assets.car (caller logs + skips).
 */
export async function buildIOSAssetCatalog(
  pngPath: string,
  tempDir: string,
  target: "ios-simulator" | "ios-device",
  minDeploymentTarget: string,
): Promise<IconResult | null> {
  const xcassetsDir = path.join(tempDir, "Assets.xcassets");
  const iconsetDir = path.join(xcassetsDir, "AppIcon.appiconset");
  await mkdir(iconsetDir, { recursive: true });

  await Bun.write(path.join(iconsetDir, "icon_1024x1024.png"), Bun.file(pngPath));

  const contentsJson = {
    images: [
      { filename: "icon_1024x1024.png", idiom: "universal", platform: "ios", size: "1024x1024" },
    ],
    info: { author: "xcode", version: 1 },
  };
  await Bun.write(path.join(iconsetDir, "Contents.json"), JSON.stringify(contentsJson, null, 2));
  await Bun.write(
    path.join(xcassetsDir, "Contents.json"),
    JSON.stringify({ info: { author: "xcode", version: 1 } }, null, 2),
  );

  const outputDir = path.join(tempDir, "actool-output");
  await mkdir(outputDir, { recursive: true });
  const platform = target === "ios-simulator" ? "iphonesimulator" : "iphoneos";

  const proc = Bun.spawn(
    [
      "xcrun", "actool", xcassetsDir,
      "--compile", outputDir,
      "--platform", platform,
      "--minimum-deployment-target", minDeploymentTarget,
      "--app-icon", "AppIcon",
      "--output-partial-info-plist", path.join(tempDir, "actool-partial.plist"),
    ],
    { stdout: "pipe", stderr: "pipe" },
  );
  const exitCode = await proc.exited;
  const carPath = path.join(outputDir, "Assets.car");
  if (exitCode !== 0 || !existsSync(carPath)) {
    const stderr = await new Response(proc.stderr).text();
    process.stderr.write(`[zapp] actool (iOS) failed: ${stderr}\n`);
    return null;
  }

  return {
    type: "assetcatalog",
    files: [{ src: carPath, dest: "Assets.car" }],
    plistKey: "CFBundleIconName",
    plistValue: "AppIcon",
  };
}
```

- [ ] **Step 2: Type-check**

Run: `cd /Users/zach/code/zapp && bunx tsc --noEmit -p cli 2>&1 | grep -i "icon.ts" || echo "no icon.ts type errors"`
Expected: `no icon.ts type errors` (the repo has ~10 pre-existing baseline tsc errors elsewhere — only `icon.ts` matters here).

- [ ] **Step 3: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/icon.ts
git commit -m "$(cat <<'EOF'
feat(cli): buildIOSAssetCatalog — single-1024 iOS app-icon catalog via actool

Modern universal/iOS asset catalog from a 1024² PNG, compiled with
actool --platform iphonesimulator|iphoneos; returns Assets.car +
CFBundleIconName, or null on actool failure (caller skips).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Wire `prepareIOSIcon` into the iOS build (zapp-cli.ts)

**Files:**
- Modify: `cli/src/zapp-cli.ts`

- [ ] **Step 1: Extend imports**

In `cli/src/zapp-cli.ts`:
- Change `import { mkdir } from "node:fs/promises";` to `import { mkdir, rm, cp } from "node:fs/promises";`.
- Add `resolveIOSIconPng` to the `./paths` import (currently `import { resolveNativeDir, resolveBootstrapDir } from "./paths";` → add it).
- Add `import { buildIOSAssetCatalog } from "./icon";`.

- [ ] **Step 2: Add the `prepareIOSIcon` helper**

Add near `writeIOSDevPlist` in `cli/src/zapp-cli.ts`:
```ts
// Resolve a PNG icon for iOS, compile it to Assets.car, copy it into the
// .app, and return "AppIcon" (the CFBundleIconName) — or null if no PNG
// icon is available or actool fails (the build proceeds without an icon).
async function prepareIOSIcon(
  root: string,
  config: { ios?: { icon?: string; minimumSystemVersion?: string }; macos?: { icon?: string } },
  target: BuildTarget,
  appBundle: string,
): Promise<string | null> {
  if (!isIOSTarget(target)) return null;
  const png = resolveIOSIconPng(root, config);
  if (!png) {
    clog(0, "[zapp] no PNG app icon for iOS (ios.icon / build/ios/icon.png / build/icon.png / macOS icon / framework default) — skipping icon");
    return null;
  }
  const tempDir = path.join(root, ".zapp", "ios-icon-tmp");
  await rm(tempDir, { recursive: true, force: true });
  await mkdir(tempDir, { recursive: true });
  try {
    const result = await buildIOSAssetCatalog(
      png, tempDir,
      target === "ios-device" ? "ios-device" : "ios-simulator",
      config.ios?.minimumSystemVersion ?? "15.0",
    );
    if (!result) return null;
    for (const f of result.files) {
      await cp(f.src, path.join(appBundle, f.dest));
    }
    return result.plistValue; // "AppIcon"
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}
```

- [ ] **Step 3: Add `iconName` to `writeIOSDevPlist`**

In `writeIOSDevPlist`'s `opts` type, add `iconName?: string | null;`. Destructure it: `const { binaryPath, config, target, iconName } = opts;`. In the plist template, insert the icon key inside the `<dict>` — add this line right after the `CFBundleSupportedPlatforms` line (line ~62):
```ts
  ${iconName ? `<key>CFBundleIconName</key><string>${iconName}</string>` : ""}
```

- [ ] **Step 4: Wire the dev iOS call site**

In `runDev`'s iOS branch, the current code is:
```ts
  if (isIOS) {
    // iOS: write Info.plist into the bundle, ad-hoc sign, install +
    // launch on the booted sim. Same flow as runBuild's iOS path.
    await writeIOSDevPlist({ binaryPath: nativeOut, config, target });
    const appBundle = path.dirname(nativeOut);
```
Replace those three statements with (compute appBundle first, prepare the icon, then write the plist with iconName):
```ts
  if (isIOS) {
    // iOS: generate the app icon, write Info.plist into the bundle, ad-hoc
    // sign, install + launch on the booted sim. Same flow as runBuild's iOS path.
    const appBundle = path.dirname(nativeOut);
    const iconName = await prepareIOSIcon(root, config, target, appBundle);
    await writeIOSDevPlist({ binaryPath: nativeOut, config, target, iconName });
```

- [ ] **Step 5: Wire the build iOS call site**

In `runBuild`'s iOS branch, the current code is:
```ts
  if (isIOSTarget(target)) {
    await writeIOSDevPlist({ binaryPath: nativeOut, config, target });
```
Replace with:
```ts
  if (isIOSTarget(target)) {
    const iconName = await prepareIOSIcon(root, config, target, path.dirname(nativeOut));
    await writeIOSDevPlist({ binaryPath: nativeOut, config, target, iconName });
```

- [ ] **Step 6: Build-verify (macOS must not regress)**

Run: `cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -1`
Expected: `[zapp] build complete: …` (CLI-only change; macOS path unchanged).

- [ ] **Step 7: Build-verify (iOS simulator) + inspect**

Run:
```bash
cd /Users/zach/code/zapp/hello-world && bun run build --platform ios-simulator 2>&1 | tail -1
plutil -p bin/ios/hello-world.app/Info.plist | grep -i icon
ls -la bin/ios/hello-world.app/Assets.car
assetutil --info bin/ios/hello-world.app/Assets.car 2>&1 | grep -i "AppIcon\|Name" | head
```
Expected: `[zapp] build complete:`; plist shows `"CFBundleIconName" => "AppIcon"`; `Assets.car` exists; `assetutil` lists an `AppIcon` entry. (hello-world has no `build/ios/icon.png`, so the **framework `zapp.png`** is used via the resolver's step 6 — confirms the reuse/fallback path end-to-end.)

- [ ] **Step 8: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/zapp-cli.ts
git commit -m "$(cat <<'EOF'
feat(cli): wire iOS app icon into the build (prepareIOSIcon + plist)

prepareIOSIcon resolves a PNG, compiles Assets.car, copies it into
bin/ios/<app>.app, and writeIOSDevPlist emits CFBundleIconName. Wired into
both the iOS dev and build paths; no PNG → logs + skips. macOS unaffected.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Docs

**Files:**
- Modify: `cli/src/config.ts` (the `IOSConfig.icon` JSDoc — make the precedence accurate)
- Modify: `docs/api-reference.md` OR `cli/README.md` (wherever the macOS icon config is documented — add the iOS parity note)

- [ ] **Step 1: Update the `IOSConfig.icon` JSDoc**

In `cli/src/config.ts`, the `IOSConfig.icon` doc currently says it falls back to `build/ios/icon.png` then `build/icon.png`. Update it to the real chain:
> Path to a 1024×1024 PNG icon source for the iOS app icon. If omitted, the CLI looks for `build/ios/icon.png`, then `build/icon.png`, then reuses the macOS PNG (`macos.icon` if it's a `.png`, or `build/macos/icon.png`), then the framework default. Must be a PNG (iOS asset catalogs don't accept `.icns`/`.iconset`); if no PNG is found the iOS build proceeds without an icon.

- [ ] **Step 2: Add a short iOS-icon note where macOS icons are documented**

Find where `macos.icon` / app icons are documented (grep `docs/` and `cli/README.md` for `icon`). Add a one-line note that iOS icons are now generated from a 1024² PNG (same source reused from macOS when no iOS-specific icon is provided), compiled into the app's `Assets.car`. Keep it brief; match the file's style.

- [ ] **Step 3: Verify + commit**

```bash
cd /Users/zach/code/zapp && bun test ./cli/src/paths.test.ts   # still 5 pass
git add cli/src/config.ts docs/api-reference.md cli/README.md   # whichever you edited
git commit -m "$(cat <<'EOF'
docs: iOS app-icon source chain + parity note

Correct IOSConfig.icon JSDoc to the real precedence (incl. macOS reuse +
framework default) and note iOS icons now generate from a 1024² PNG.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review (completed during plan authoring)

**Spec coverage:**
- §1 `resolveIOSIconPng` (6-step PNG chain, "" if none) → Task 1 (TDD). ✅
- §2 `buildIOSAssetCatalog` (single 1024² universal-iOS, actool per-platform, IconResult/null) → Task 2. ✅
- §3 `prepareIOSIcon` + `writeIOSDevPlist` `iconName` + both call sites + Assets.car→`.app` root → Task 3. ✅
- §4 verification (bun test; macOS + ios-sim build; plutil/assetutil) → Tasks 1 + 3. ✅
- §6 non-goals (no extraction, no legacy matrix, macOS untouched) → respected; nothing tasked outside. ✅
- Docs (IOSConfig.icon accuracy) → Task 4. ✅

**Placeholder scan:** No TBD/placeholders; all code complete. The only "find the right doc spot" (Task 4 Step 2) is a deliberate grep-then-edit with the exact content specified.

**Type/name consistency:** `resolveIOSIconPng(root, config)`, `buildIOSAssetCatalog(pngPath, tempDir, target, minDeploymentTarget)` returning `IconResult | null`, `prepareIOSIcon(root, config, target, appBundle)` returning `string | null`, and `writeIOSDevPlist`'s new `iconName?: string | null` are used consistently across Tasks 1–3. `plistValue: "AppIcon"` flows from `buildIOSAssetCatalog` → `prepareIOSIcon` return → `writeIOSDevPlist` `CFBundleIconName`. The `IconResult` type + `Assets.car` dest are reused from the existing `icon.ts`.
