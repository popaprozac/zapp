# Nim Prod macOS Build (gap #1) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** The Nim build path produces a distributable macOS binary — web assets embedded via Nim stdlib `staticRead`, prod build-config (no devtools, embedded assets), and `zapp package` yields a self-contained `.app`.

**Architecture:** A new CLI emitter generates `.zapp/zapp_assets.nim` (a `{.exportc.}` `zapp_embedded_assets[]` table built from `staticRead` of the existing `.br` payloads) — matching the C-ABI `webview.m` already reads. `buildNativeNim` always emits it (dev → count-0 stub; prod → full table) and threads `embedAssets`/`devTools`/`isDev`/`optimize` + CSP/protocols into the build-config by mode. `createProductionBundle` switches to a language-agnostic `.zapp/assets-embedded` marker. Compression stays in the TS CLI; runtime decode stays Apple `libcompression`.

**Tech Stack:** TS (Bun, `cli/src/assets.ts`/`native.ts`/`build-config.ts`/`package.ts`), Nim (`zapp.nim` + generated `zapp_assets.nim`), bun:test.

**Spec:** `docs/superpowers/specs/2026-06-18-nim-prod-macos-build-design.md`

---

### Task 1: `renderAssetsNim` pure renderer + tests (TDD)

**Files:**
- Modify: `cli/src/assets.ts` (add `renderAssetsNim` + export `AssetEntry` if not already)
- Test: `cli/src/assets.test.ts` (create or append)

- [ ] **Step 1: Write the failing test.** In `cli/src/assets.test.ts`:
```ts
import { test, expect } from "bun:test";
import { renderAssetsNim, type AssetEntry } from "./assets";

test("renderAssetsNim emits an exportc table from staticRead, brotli on", () => {
  const assets: AssetEntry[] = [
    { relPath: "/index.html", brPath: "/x/.zapp/assets/index.html.br", originalSize: 1234 },
    { relPath: "/assets/app.js", brPath: "/x/.zapp/assets/assets/app.js.br", originalSize: 5678 },
  ];
  const out = renderAssetsNim(assets, /*compress*/ true);
  // staticRead of each .br, path relative to .zapp/ (where the module lives)
  expect(out).toContain('staticRead("assets/index.html.br")');
  expect(out).toContain('staticRead("assets/assets/app.js.br")');
  // exportc symbols the .m reads
  expect(out).toContain("zapp_embedded_assets");
  expect(out).toContain("zapp_embedded_assets_count");
  expect(out).toContain('path: cstring"/index.html"');
  expect(out).toContain("uncompressed_len: cint(1234)");
  expect(out).toContain("is_brotli: cint(1)");
  expect(out).toContain("cint(2)"); // count = 2
});

test("renderAssetsNim emits a count-0 stub for an empty set (links, no staticRead)", () => {
  const out = renderAssetsNim([], true);
  expect(out).toContain("zapp_embedded_assets_count");
  expect(out).toContain("cint(0)");
  expect(out).not.toContain("staticRead(");
});
```

- [ ] **Step 2: Run it (fails — `renderAssetsNim` undefined).** `cd cli && bun test src/assets.test.ts` → FAIL.

- [ ] **Step 3: Implement `renderAssetsNim`.** In `cli/src/assets.ts`, add (the `.br` path passed to `staticRead` is relative to `.zapp/`, where the generated module lives: `"assets" + relPath + (compress ? ".br" : "")`):
```ts
export function renderAssetsNim(assets: AssetEntry[], compress: boolean): string {
  const brotli = compress ? 1 : 0;
  let s = "## AUTO-GENERATED — embedded assets (brotli), Nim build. DO NOT EDIT.\n";
  s += "type ZappEmbeddedAsset {.exportc, bycopy.} = object\n";
  s += "  path: cstring\n  data: ptr uint8\n  len: cint\n  uncompressed_len: cint\n  is_brotli: cint\n\n";
  if (assets.length === 0) {
    // Empty/dev: keep the symbols linking; count 0 → webview falls back to filesystem.
    s += "var zapp_embedded_assets* {.exportc.}: array[1, ZappEmbeddedAsset]\n";
    s += "var zapp_embedded_assets_count* {.exportc.}: cint = cint(0)\n";
    return s;
  }
  // `let` (not const) so unsafeAddr is valid; bytes are baked at compile time,
  // the global lives for program lifetime (webview reads synchronously).
  assets.forEach((a, i) => {
    const rel = "assets" + a.relPath + (compress ? ".br" : "");
    s += `let a${i} = staticRead("${rel}")\n`;
  });
  s += `\nvar zapp_embedded_assets* {.exportc.}: array[${assets.length}, ZappEmbeddedAsset] = [\n`;
  assets.forEach((a, i) => {
    const esc = a.relPath.replace(/\\/g, "/").replace(/"/g, '\\"');
    s += `  ZappEmbeddedAsset(path: cstring"${esc}", ` +
         `data: cast[ptr uint8](unsafeAddr a${i}[0]), len: a${i}.len.cint, ` +
         `uncompressed_len: cint(${a.originalSize}), is_brotli: cint(${brotli})),\n`;
  });
  s += "]\n";
  s += `var zapp_embedded_assets_count* {.exportc.}: cint = cint(${assets.length})\n`;
  return s;
}
```
Ensure `AssetEntry` is `export`ed (it's defined in assets.ts for `generateAssetManifest`).

- [ ] **Step 4: Run it (passes).** `cd cli && bun test src/assets.test.ts` → PASS.

- [ ] **Step 5: Commit.**
```bash
cd /Users/zach/code/zapp
git add cli/src/assets.ts cli/src/assets.test.ts
git commit -m "feat(cli): renderAssetsNim — staticRead embedded-asset table (TDD)"
```
(Trailer last line EXACTLY `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.)

---

### Task 2: Nim asset emitter + marker + zapp.nim consumes it (dev path green)

**Files:**
- Modify: `cli/src/assets.ts` (`generateAssetManifestNim` + marker; marker in `generateAssetManifest`)
- Modify: `native/nim/zapp.nim` (drop inline stub; `import zapp_assets`)
- Modify: `cli/src/native.ts` `buildNativeNim` (always emit the asset module — dev stub)

- [ ] **Step 1: Factor the asset collection** so both emitters share it. In `cli/src/assets.ts`, extract the walk + brotli + write-`.br` loop from `generateAssetManifest` into `async function collectAssets(root, assetDir): Promise<{assets: AssetEntry[], compress: boolean}>`. Have the existing `generateAssetManifest` call it (behavior unchanged — verify the zc build still produces the same `.zapp/zapp_assets.zc`).

- [ ] **Step 2: Add `generateAssetManifestNim`.** In `cli/src/assets.ts`:
```ts
const ASSETS_EMBEDDED_MARKER = ".zapp/assets-embedded";

export async function generateAssetManifestNim(root: string, assetDir: string,
                                               opts: { embed: boolean }): Promise<string> {
  const zappDir = path.join(root, ".zapp");
  await mkdir(zappDir, { recursive: true });
  const outPath = path.join(zappDir, "zapp_assets.nim");
  const markerPath = path.join(root, ASSETS_EMBEDDED_MARKER);
  if (!opts.embed) {
    // Dev: count-0 stub so `import zapp_assets` resolves; filesystem fallback.
    await Bun.write(outPath, renderAssetsNim([], true));
    await rm(markerPath, { force: true });           // no embed → no marker
    return outPath;
  }
  const { assets, compress } = await collectAssets(root, assetDir);
  await Bun.write(outPath, renderAssetsNim(assets, compress));
  await Bun.write(markerPath, "");                    // embed → marker
  return outPath;
}
```
(Import `rm` from node:fs/promises if not present.)

- [ ] **Step 3: zc emitter writes the marker too.** In `generateAssetManifest` (zc), after writing `zapp_assets.zc`, `await Bun.write(path.join(root, ASSETS_EMBEDDED_MARKER), "")` — so the marker is the single source of truth for "assets embedded," written by both prod emitters. (The zc dev stub path in `zapp-cli.ts` does NOT write it.)

- [ ] **Step 4: zapp.nim consumes the generated module.** In `native/nim/zapp.nim` (~lines 168-184), DELETE the inline `type ZappEmbeddedAsset` + empty `zapp_embedded_assets`/`_count` stub, and add `import zapp_assets` (resolved via the existing `--path:${zappDir}`). The generated module now owns the type + table.

- [ ] **Step 5: buildNativeNim always emits the asset module.** In `cli/src/native.ts` `buildNativeNim`, before the `nim c` invocation, call `generateAssetManifestNim(root, config.assetDir, { embed: false })` (dev stub for now — Task 3 flips `embed` by mode). This makes `import zapp_assets` resolve. (Import it alongside the other `./build-config`/`./assets` dynamic imports the function already uses.)

- [ ] **Step 6: Build both (dev shapes).**
  - Nim: `cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build` → `[zapp] build complete:` (emits a count-0 `zapp_assets.nim`; still filesystem-served — unchanged dev behavior).
  - zc: `cd /Users/zach/code/zapp/kitchen-sink && bun run build` → `[zapp] build complete:` (now also drops the marker — verify zc build still completes).

- [ ] **Step 7: Commit.**
```bash
cd /Users/zach/code/zapp
git add cli/src/assets.ts native/nim/zapp.nim cli/src/native.ts
git commit -m "feat(cli): Nim asset-manifest emitter + embed marker; zapp.nim consumes generated table"
```

---

### Task 3 (GATE): Prod flags through buildNativeNim → self-contained binary

**Files:**
- Modify: `cli/src/native.ts` (`buildNativeNim` signature + call site + flags)
- Modify: `cli/src/build-config.ts` (`renderBuildConfigNim` CSP + custom protocols)

- [ ] **Step 1: Thread `optimize` into `buildNativeNim`.** Change `compileNative`'s Nim branch (`native.ts:~1268`) to pass `opts.optimize` (the zc path already sets `optimize:true` for `zapp build`/`package`, `false` for `zapp dev`). Add the param to `buildNativeNim`.

- [ ] **Step 2: Set build-config + asset embed by mode.** In `buildNativeNim`, let `const prod = optimize`. Change the `renderBuildConfigNim({...})` call: `embedAssets: prod`, `devTools: prod ? 0 : 1`, `isDev: !prod`, `assetRoot: prod ? "" : assetRoot`. And call `generateAssetManifestNim(root, config.assetDir, { embed: prod })` (real table + marker in prod; stub in dev) instead of the always-`embed:false` from Task 2 Step 5.

- [ ] **Step 3: Thread CSP + custom protocols into `renderBuildConfigNim`.** It currently hardcodes `csp=""` / `custom_protocols_json="[]"` (`build-config.ts:~217,220`). Add `csp` + `customProtocolsJson` params (mirror how the zc `generateBuildConfig` derives them from `config`) and pass the real values from `buildNativeNim` (read how the zc path computes CSP + protocols from `config` and reuse). If the derivation is non-trivial, factor the shared helper; report what you did.

- [ ] **Step 4: Build prod + assert embedded.**
  - `cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build` → `[zapp] build complete:`.
  - Assert: `.zapp/zapp_assets.nim` has a NON-empty table (`grep -c ZappEmbeddedAsset(` > 1) and `grep zapp_embedded_assets_count .zapp/zapp_assets.nim` shows a non-zero count; `.zapp/assets-embedded` exists; the generated `.zapp/zapp_build_config.nim` shows `zapp_build_use_embedded_assets … = cint(1)` and `zapp_build_dev_tools_default … = 0`.
  - Dev still filesystem: `ZAPP_NATIVE_LANG=nim bun run dev`-shaped build (or assert the dev path emits count-0 + no marker).

- [ ] **Step 5: GATE — self-contained smoke (human).** Build prod (above), then temporarily move `kitchen-sink/dist` aside and launch `kitchen-sink/bin/kitchen-sink` directly → the app UI still loads (served from the embedded table, not the filesystem). Restore `dist`. PAUSE for human confirmation. (Automated portion — embedAssets=1 + non-empty table — is checked in Step 4.)

- [ ] **Step 6: Commit.**
```bash
cd /Users/zach/code/zapp
git add cli/src/native.ts cli/src/build-config.ts
git commit -m "feat(cli): Nim build embeds assets + prod build-config in optimize mode"
```

---

### Task 4 (GATE): Marker-based embedded-detection in packaging

**Files:**
- Modify: `cli/src/package.ts` (`createProductionBundle` embedded-detection)

- [ ] **Step 1: Switch detection to the marker.** In `createProductionBundle` (`package.ts:~50`), replace the `existsSync(.zapp/zapp_assets.zc)` check with `existsSync(path.join(root, ".zapp", "assets-embedded"))`:
  - marker present → embedded branch (log "assets embedded in binary"; skip copying `dist/`).
  - marker absent → filesystem branch (copy `dist/` into `Resources/`).
  This is language-agnostic (zc-prod + nim-prod both write it) and fixes the latent zc dev-stub bug (the stub never wrote a marker).

- [ ] **Step 2: Build + package the nim kitchen-sink.**
  - `cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run package` (macOS) → succeeds; the produced `.app` is created.
  - Assert: the embedded branch was taken — `Contents/Resources/` does NOT contain a copied `dist/` (the `index.html` etc. live in the binary). The `.app/Contents/MacOS/<bin>` exists.

- [ ] **Step 3: zc package unaffected.** `cd /Users/zach/code/zapp/kitchen-sink && bun run package` → succeeds, embedded branch (marker written by `generateAssetManifest`). (Confirms the shared marker didn't regress zc packaging.)

- [ ] **Step 4: GATE — detached-app smoke (human).** Launch the packaged nim `.app` from `release/` with NO sibling `dist/` → it runs with embedded assets. PAUSE for human confirmation.

- [ ] **Step 5: Commit.**
```bash
cd /Users/zach/code/zapp
git add cli/src/package.ts
git commit -m "fix(package): marker-based embedded-asset detection (nim-aware; fixes zc dev-stub bug)"
```

---

### Task 5: Docs + final gate

**Files:**
- Modify: `docs/api-reference.md` (or the build/packaging doc) + `docs/nim-migration-roadmap.md` (tick gap #1)

- [ ] **Step 1: Docs.** Note that the Nim build now produces a distributable macOS binary (embedded assets via `staticRead`, prod build-config, `zapp package` → self-contained `.app`). In `docs/nim-migration-roadmap.md`, mark gap #1 done + note assets are now zc-free (down-payment on gap #2).

- [ ] **Step 2: Full gate.**
```bash
cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build   # [zapp] build complete:
cd /Users/zach/code/zapp/kitchen-sink && bun run build                         # [zapp] build complete: (zc)
cd /Users/zach/code/zapp && bun run check                                      # tsc clean
cd /Users/zach/code/zapp/cli && bun test src                                   # all pass (incl. assets.test.ts)
cd /Users/zach/code/zapp/native/nim && nim c -r --hints:off --mm:orc --threads:on -o:/tmp/wm tests/windowmanager_test.nim  # ok (no native-test regression)
```

- [ ] **Step 3: Commit docs.**
```bash
cd /Users/zach/code/zapp
git add docs/api-reference.md docs/nim-migration-roadmap.md
git commit -m "docs: Nim prod macOS build (embedded assets, distributable)"
```

---

## Self-review notes
- **Always-green builds:** Task 2 wires `import zapp_assets` + always-emit (dev stub) so the dev build stays green BEFORE Task 3 flips prod embedding. Task 3 is the atomic "prod embeds" step.
- **`let` not `const` for staticRead data:** so `unsafeAddr a${i}[0]` is valid (a const can't reliably take an address); the bytes are still baked at compile time, the module-global `let` lives for program lifetime — matches the webview's synchronous read.
- **Empty-set / dev:** `renderAssetsNim([])` emits a `count=0` `array[1]` stub (Nim has no `array[0,T]`) so symbols link + the webview falls back to filesystem. No `staticRead` in the stub.
- **Marker is the single source of truth:** both prod emitters (zc `generateAssetManifest`, nim `generateAssetManifestNim{embed:true}`) write `.zapp/assets-embedded`; dev/stub paths don't. Fixes the pre-existing zc dev-stub packaging bug + makes detection language-agnostic.
- **Type consistency:** the generated `ZappEmbeddedAsset` matches `webview.m`'s struct (`path:cstring,data:ptr uint8,len:cint,uncompressed_len:cint,is_brotli:cint`) + the `zapp_embedded_assets`/`_count` `{.exportc.}` symbols; `zapp.nim` drops its now-duplicate stub.
- **Scope:** zc-transpile of the JsonValue provider + zjs build is untouched (gap #2). Assets become zc-free as a side benefit. CSP/protocols threading included so a prod build doesn't silently drop configured values.
