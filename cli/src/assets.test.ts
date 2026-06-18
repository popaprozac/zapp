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

test("renderAssetsNim with compress off drops the .br suffix and is_brotli", () => {
  const assets: AssetEntry[] = [
    { relPath: "/index.html", brPath: "/x/.zapp/assets/index.html", originalSize: 1234 },
  ];
  const out = renderAssetsNim(assets, /*compress*/ false);
  expect(out).toContain('staticRead("assets/index.html")');
  expect(out).not.toContain(".br");
  expect(out).toContain("is_brotli: cint(0)");
});

test("renderAssetsNim emits a count-0 stub for an empty set (links, no staticRead)", () => {
  const out = renderAssetsNim([], true);
  expect(out).toContain("zapp_embedded_assets_count");
  expect(out).toContain("cint(0)");
  expect(out).not.toContain("staticRead(");
});
