import { test, expect } from "bun:test";
import { renderAssetsNim, type AssetEntry } from "./assets";

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
