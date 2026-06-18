// Asset embedding — brotli-compresses Vite output and generates Zen-C embed directives.
// Assets are compiled directly into the binary. Decompressed at runtime in the scheme handler.

import path from "node:path";
import { mkdir, readdir, stat } from "node:fs/promises";
import { existsSync } from "node:fs";
import { brotliCompressSync, constants } from "node:zlib";
import { clog } from "./log";

export interface AssetEntry {
  relPath: string;   // e.g. "/index.html"
  brPath: string;    // absolute path to .br file
  originalSize: number;
}

/** Recursively walk a directory and return all file paths. */
async function walkDir(dir: string): Promise<string[]> {
  const results: string[] = [];
  const entries = await readdir(dir, { withFileTypes: true });
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      results.push(...await walkDir(full));
    } else {
      results.push(full);
    }
  }
  return results;
}

/**
 * Compress all files in distDir with brotli, generate a Zen-C file with embed directives.
 * Returns the path to the generated .zapp/zapp_assets.zc file.
 */
export async function generateAssetManifest(root: string, assetDir: string): Promise<string> {
  const distDir = path.resolve(root, assetDir);
  const zappDir = path.join(root, ".zapp");
  const brDir = path.join(zappDir, "assets");
  await mkdir(brDir, { recursive: true });

  // Windows embeds RAW bytes: the brotli decode at runtime uses Apple's
  // libcompression (bare.c bare_load_script / the darwin scheme handler),
  // which has no Windows counterpart yet. Workers read embedded assets
  // on Windows (the webview serves from the on-disk dist folder), so
  // compressed embeds mean headless workers silently fail to load.
  // Costs binary size only; revisit if a portable brotli decoder lands.
  const compress = process.platform !== "win32";

  // Collect all files from Vite dist/ output (includes _workers/ from Vite plugin)
  const files = await walkDir(distDir);
  const assets: AssetEntry[] = [];
  let totalOriginal = 0;
  let totalCompressed = 0;

  for (const file of files) {
    const relPath = "/" + path.relative(distDir, file).replace(/\\/g, "/");
    const source = await Bun.file(file).arrayBuffer();
    const compressed = compress
      ? brotliCompressSync(new Uint8Array(source), {
          params: { [constants.BROTLI_PARAM_QUALITY]: 11 },
        })
      : new Uint8Array(source);

    // Write the embed payload (compressed or raw copy)
    const brRelPath = relPath + (compress ? ".br" : "");
    const brPath = path.join(brDir, brRelPath);
    await mkdir(path.dirname(brPath), { recursive: true });
    await Bun.write(brPath, compressed);

    assets.push({ relPath, brPath, originalSize: source.byteLength });
    totalOriginal += source.byteLength;
    totalCompressed += compressed.byteLength;
  }

  // Generate Zen-C file with embed directives
  let zc = "// AUTO-GENERATED — embedded assets with brotli compression.\n";
  zc += `// ${assets.length} files, ${Math.round(totalOriginal / 1024)} KB → ${Math.round(totalCompressed / 1024)} KB\n\n`;

  // Embed directives — each asset becomes a byte array in the binary.
  // Forward slashes: Windows backslash paths ("C:\Users\...") land in
  // generated C where \U starts a universal character name and fails
  // to compile.
  for (let i = 0; i < assets.length; i++) {
    zc += `let __zapp_asset_${i} = embed "${assets[i].brPath.replace(/\\/g, "/")}" as u8[];\n`;
  }

  // Accessor functions — bridge Zen-C embed results to C
  for (let i = 0; i < assets.length; i++) {
    zc += `fn __zapp_asset_${i}_data() -> u8* { return __zapp_asset_${i}.data; }\n`;
    zc += `fn __zapp_asset_${i}_len() -> int { return __zapp_asset_${i}.len; }\n`;
  }

  // Asset array initialization (raw C)
  zc += `\nraw {\n`;
  // libcompression is Apple-only; the darwin scheme handler does the
  // brotli decode. Windows serves assets via WebView2 virtual-host
  // mapping and never touches this header.
  zc += `    #if defined(__APPLE__)\n`;
  zc += `    #include <compression.h>\n`;
  zc += `    #endif\n\n`;
  zc += `    #ifndef ZAPP_EMBEDDED_ASSET_DEFINED\n`;
  zc += `    #define ZAPP_EMBEDDED_ASSET_DEFINED\n`;
  zc += `    typedef struct {\n`;
  zc += `        const char* path;\n`;
  zc += `        uint8_t* data;\n`;
  zc += `        int len;\n`;
  zc += `        int uncompressed_len;\n`;
  zc += `        int is_brotli;\n`;
  zc += `    } ZappEmbeddedAsset;\n`;
  zc += `    #endif\n\n`;
  zc += `    ZappEmbeddedAsset zapp_embedded_assets[${assets.length}];\n`;
  zc += `    int zapp_embedded_assets_count = ${assets.length};\n\n`;

  // Declare accessor functions
  for (let i = 0; i < assets.length; i++) {
    zc += `    extern uint8_t* __zapp_asset_${i}_data(void);\n`;
    zc += `    extern int __zapp_asset_${i}_len(void);\n`;
  }

  zc += `\n    __attribute__((constructor))\n`;
  zc += `    static void init_zapp_assets(void) {\n`;

  for (let i = 0; i < assets.length; i++) {
    const a = assets[i];
    zc += `        zapp_embedded_assets[${i}].path = "${a.relPath}";\n`;
    zc += `        zapp_embedded_assets[${i}].data = __zapp_asset_${i}_data();\n`;
    zc += `        zapp_embedded_assets[${i}].len = __zapp_asset_${i}_len();\n`;
    zc += `        zapp_embedded_assets[${i}].uncompressed_len = ${a.originalSize};\n`;
    zc += `        zapp_embedded_assets[${i}].is_brotli = ${compress ? 1 : 0};\n`;
  }

  zc += `    }\n`;
  zc += `}\n`;

  const outPath = path.join(zappDir, "zapp_assets.zc");
  await Bun.write(outPath, zc);

  clog(1,
    `compressed ${assets.length} assets: ` +
    `${Math.round(totalOriginal / 1024)} KB → ${Math.round(totalCompressed / 1024)} KB ` +
    `(${Math.round((1 - totalCompressed / totalOriginal) * 100)}% reduction)`
  );

  return outPath;
}

/**
 * Render a Nim source module that embeds all assets via `staticRead`.
 * The emitted module exposes `{.exportc.}` symbols that the native scheme
 * handler (native/platform/darwin/webview.m) reads via the C ABI:
 *   - zapp_embedded_assets: array[N, ZappEmbeddedAsset]
 *   - zapp_embedded_assets_count: cint
 *
 * The `staticRead` path is reconstructed from `relPath` (the `brPath` field
 * is not used here). The module is written into `.zapp/`, so paths are
 * relative to that dir (e.g. "assets/index.html.br").
 */
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
    // relPath is Vite-generated (hashed, [a-zA-Z0-9_-./]) → no quote escaping
    // needed for the staticRead literal; the cstring path below escapes anyway.
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
