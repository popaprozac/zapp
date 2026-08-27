import { test, expect } from "bun:test";
import {
  ASSETS_EMBEDDED_MARKER,
  generateAssetManifestC,
  generateAssetManifestNim,
  renderAssetsC,
  renderAssetsNim,
  type AssetEntry,
} from "./assets";
import { mkdtemp, rm, mkdir, writeFile, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

async function pathExists(p: string): Promise<boolean> {
  try { await stat(p); return true; } catch { return false; }
}

test("renderAssetsNim emits an exportc table from staticRead, brotli on", () => {
  const assets: AssetEntry[] = [
    { relPath: "/index.html", brPath: "/x/.zapp/assets/index.html.br", originalSize: 1234, brotli: true },
    { relPath: "/assets/app.js", brPath: "/x/.zapp/assets/assets/app.js.br", originalSize: 5678, brotli: true },
  ];
  const out = renderAssetsNim(assets);
  // staticRead of each .br, path relative to .zapp/ (where the module lives)
  expect(out).toContain('staticRead("assets/index.html.br")');
  expect(out).toContain('staticRead("assets/assets/app.js.br")');
  // const (compile-time embed) + let (addressable, immutable) — NOT `let = staticRead`
  // directly, which doesn't compile (staticRead needs a compile-time context).
  expect(out).toContain('const a0Const = staticRead(');
  expect(out).toContain('let a0: string = a0Const');
  // exportc symbols the .m reads
  expect(out).toContain("zapp_embedded_assets");
  expect(out).toContain("zapp_embedded_assets_count");
  expect(out).toContain('path: cstring"/index.html"');
  expect(out).toContain("uncompressed_len: cint(1234)");
  expect(out).toContain("is_brotli: cint(1)");
  expect(out).toContain("cint(2)"); // count = 2
});

test("renderAssetsNim stores an incompressible asset raw (per-asset is_brotli)", () => {
  const assets: AssetEntry[] = [
    { relPath: "/index.html", brPath: "/x/.zapp/assets/index.html.br", originalSize: 100, brotli: true },
    { relPath: "/logo.png", brPath: "/x/.zapp/assets/logo.png", originalSize: 200, brotli: false },
  ];
  const out = renderAssetsNim(assets);
  // brotli'd asset → .br suffix + is_brotli 1
  expect(out).toContain('staticRead("assets/index.html.br")');
  expect(out).toContain("is_brotli: cint(1)");
  // raw asset → no .br suffix + is_brotli 0
  expect(out).toContain('staticRead("assets/logo.png")');
  expect(out).toContain("is_brotli: cint(0)");
  expect(out).not.toContain("assets/logo.png.br");
});

test("renderAssetsNim emits a count-0 stub for an empty set (links, no staticRead)", () => {
  const out = renderAssetsNim([]);
  expect(out).toContain("zapp_embedded_assets_count");
  expect(out).toContain("cint(0)");
  expect(out).not.toContain("staticRead(");
});

test("generateAssetManifestNim embed:false writes a count-0 stub and removes the marker", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "zapp-assets-"));
  try {
    // Pre-seed a stale marker so we prove the dev path actively removes it.
    await mkdir(path.join(root, ".zapp"), { recursive: true });
    await writeFile(path.join(root, ASSETS_EMBEDDED_MARKER), "");
    expect(await pathExists(path.join(root, ASSETS_EMBEDDED_MARKER))).toBe(true);

    const out = await generateAssetManifestNim(root, "dist", { embed: false });

    expect(out).toBe(path.join(root, ".zapp", "zapp_assets.nim"));
    expect(await pathExists(out)).toBe(true);
    const nim = await Bun.file(out).text();
    expect(nim).toContain("cint(0)");          // count-0 stub
    expect(nim).not.toContain("staticRead(");   // dev: no embeds
    expect(await pathExists(path.join(root, ASSETS_EMBEDDED_MARKER))).toBe(false); // marker removed
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("generateAssetManifestNim embed:true writes the embed marker + a populated table", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "zapp-assets-"));
  try {
    const assetDir = path.join(root, "dist");
    await mkdir(assetDir, { recursive: true });
    await writeFile(path.join(assetDir, "index.html"), "<!doctype html><title>t</title>");

    // compress:false keeps the test off brotli; collectAssets stores raw bytes.
    const out = await generateAssetManifestNim(root, "dist", { embed: true, compress: false });

    expect(await pathExists(out)).toBe(true);
    expect(await pathExists(path.join(root, ASSETS_EMBEDDED_MARKER))).toBe(true); // marker written
    const nim = await Bun.file(out).text();
    expect(nim).toContain("zapp_embedded_assets_count");
    expect(nim).toContain('path: cstring"/index.html"'); // the asset made it into the table
    expect(nim).toContain("cint(1)");                     // count = 1
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("renderAssetsC emits an immutable process-lifetime byte table", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "zapp-assets-c-"));
  try {
    const payload = path.join(root, "index.html");
    await writeFile(payload, "hello");
    const out = await renderAssetsC([{
      relPath: "/index.html",
      brPath: payload,
      originalSize: 5,
      brotli: false,
    }]);
    expect(out).toContain("static const uint8_t zapp_desktop_asset_0[]");
    expect(out).toContain("0x68, 0x65, 0x6c, 0x6c, 0x6f");
    expect(out).toContain('{ "/index.html", zapp_desktop_asset_0');
    expect(out).toContain("zapp_desktop_asset_0, 5, 5, 0");
    expect(out).toContain("const size_t zapp_desktop_assets_count = 1");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("renderAssetsC represents an empty asset without extending its logical length", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "zapp-assets-c-"));
  try {
    const payload = path.join(root, "empty.txt");
    await writeFile(payload, "");
    const out = await renderAssetsC([{
      relPath: "/empty.txt",
      brPath: payload,
      originalSize: 0,
      brotli: false,
    }]);
    expect(out).toContain("zapp_desktop_asset_0[] = {\n  0x00,");
    expect(out).toContain("zapp_desktop_asset_0, 0, 0, 0");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("generateAssetManifestC emits a linkable empty development table", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "zapp-assets-c-"));
  try {
    const out = await generateAssetManifestC(root, "missing", { embed: false });
    expect(await pathExists(out)).toBe(true);
    const source = await Bun.file(out).text();
    expect(source).toContain("zapp_desktop_assets[1] = {{0}}");
    expect(source).toContain("zapp_desktop_assets_count = 0");
    expect(await pathExists(path.join(root, ASSETS_EMBEDDED_MARKER))).toBe(false);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("generateAssetManifestC records when production assets are embedded", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "zapp-assets-c-"));
  try {
    const assetDir = path.join(root, "dist");
    await mkdir(assetDir, { recursive: true });
    await writeFile(path.join(assetDir, "index.html"), "<!doctype html>");
    await generateAssetManifestC(root, "dist", {
      embed: true,
      compress: false,
    });
    expect(await pathExists(path.join(root, ASSETS_EMBEDDED_MARKER))).toBe(true);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
