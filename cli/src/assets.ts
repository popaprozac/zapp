// Asset embedding — brotli-compresses Vite output and generates Zen-C embed directives.
// Assets are compiled directly into the binary. Decompressed at runtime in the scheme handler.

import path from "node:path";
import { mkdir, readdir, rm, stat } from "node:fs/promises";
import { existsSync } from "node:fs";
import { brotliCompressSync, constants } from "node:zlib";
import { clog } from "./log";

/** Marker written by both prod asset emitters (zc + Nim) to signal that
 *  assets are baked into the binary. The zc DEV stub path does NOT write it. */
export const ASSETS_EMBEDDED_MARKER = ".zapp/assets-embedded";

export interface AssetEntry {
  relPath: string;   // e.g. "/index.html"
  brPath: string;    // absolute path to the stored payload (.br when brotli'd)
  originalSize: number;
  compressedSize?: number;  // set by collectAssets; optional so test fixtures stay concise
  /** Whether THIS asset's stored payload is brotli-compressed. Per-asset (not
   *  global): already-compressed types (png/woff2/...) are stored raw even when
   *  compression is on, since brotli q11 on them burns build time for ~0 gain.
   *  Optional so test fixtures stay concise; the emitters default it to true. */
  brotli?: boolean;
}

/** Extensions whose bytes are already compressed — brotli q11 on them costs
 *  build time + a runtime decode for negligible (often negative) size change,
 *  so they're embedded raw even when compression is enabled. */
const INCOMPRESSIBLE_EXTS = new Set([
  ".png", ".jpg", ".jpeg", ".gif", ".webp", ".avif", ".ico",
  ".woff", ".woff2", ".mp4", ".webm", ".mov", ".mp3", ".ogg", ".m4a",
  ".br", ".gz", ".zip", ".zst",
]);

function isIncompressible(relPath: string): boolean {
  return INCOMPRESSIBLE_EXTS.has(path.extname(relPath).toLowerCase());
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
 * Walk `assetDir`, brotli-compress each file into `.zapp/assets/`, and return
 * the collected asset metadata. Shared by the zc and Nim emitters.
 */
async function collectAssets(
  root: string,
  assetDir: string,
  compress: boolean,
): Promise<{ assets: AssetEntry[] }> {
  const distDir = path.resolve(root, assetDir);
  const zappDir = path.join(root, ".zapp");
  const brDir = path.join(zappDir, "assets");
  await mkdir(brDir, { recursive: true });

  // Windows embeds RAW bytes regardless of the `compress` preference: the brotli
  // decode at runtime uses Apple's libcompression (bare.c bare_load_script / the
  // darwin scheme handler), which has no Windows counterpart yet. Workers read
  // embedded assets on Windows, so compressed embeds would silently fail to load.
  // Costs binary size only; revisit if a portable brotli decoder lands (task #516).
  const compressOk = compress && process.platform !== "win32";

  const files = await walkDir(distDir);
  const assets: AssetEntry[] = [];

  for (const file of files) {
    const relPath = "/" + path.relative(distDir, file).replace(/\\/g, "/");
    const source = await Bun.file(file).arrayBuffer();
    // Per-asset: skip brotli for already-compressed types (png/woff2/...) even
    // when compression is on — q11 on them is wasted build time + a useless
    // runtime decode. The runtime reads is_brotli per asset, so a mixed table is fine.
    const brotli = compressOk && !isIncompressible(relPath);
    const payload = brotli
      ? brotliCompressSync(new Uint8Array(source), {
          params: { [constants.BROTLI_PARAM_QUALITY]: 11 },
        })
      : new Uint8Array(source);

    // Write the embed payload (compressed → .br suffix, raw → bare name).
    const brPath = path.join(brDir, relPath + (brotli ? ".br" : ""));
    await mkdir(path.dirname(brPath), { recursive: true });
    await Bun.write(brPath, payload);

    assets.push({ relPath, brPath, originalSize: source.byteLength, compressedSize: payload.byteLength, brotli });
  }

  return { assets };
}

/**
 * Compress all files in distDir with brotli, generate a Zen-C file with embed directives.
 * Returns the path to the generated .zapp/zapp_assets.zc file.
 *
 * NOTE: This function writes the `.zapp/assets-embedded` marker (ASSETS_EMBEDDED_MARKER)
 * as part of its normal flow. It MUST NOT be called from any dev or stub-emit path —
 * only call it when assets are genuinely being baked into the binary (prod builds).
 */
export async function generateAssetManifest(root: string, assetDir: string,
                                            compress = true): Promise<string> {
  const zappDir = path.join(root, ".zapp");
  await mkdir(zappDir, { recursive: true });

  const { assets } = await collectAssets(root, assetDir, compress);
  let totalOriginal = 0;
  let totalCompressed = 0;
  for (const a of assets) {
    totalOriginal += a.originalSize;
    totalCompressed += a.compressedSize ?? a.originalSize;
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
    zc += `        zapp_embedded_assets[${i}].is_brotli = ${a.brotli ? 1 : 0};\n`;
  }

  zc += `    }\n`;
  zc += `}\n`;

  const outPath = path.join(zappDir, "zapp_assets.zc");
  await Bun.write(outPath, zc);

  // Marker: present iff assets are baked into the binary (both prod emitters write it).
  await Bun.write(path.join(root, ASSETS_EMBEDDED_MARKER), "");

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
 * relative to that dir (e.g. "assets/index.html.br"). brotli is decided
 * per-asset (`a.brotli`): incompressible types are stored raw + is_brotli=0.
 */
export function renderAssetsNim(assets: AssetEntry[]): string {
  let s = "## AUTO-GENERATED — embedded assets (brotli), Nim build. DO NOT EDIT.\n";
  s += "type ZappEmbeddedAsset {.exportc, bycopy.} = object\n";
  s += "  path: cstring\n  data: ptr uint8\n  len: cint\n  uncompressed_len: cint\n  is_brotli: cint\n\n";
  if (assets.length === 0) {
    // Empty/dev: keep the symbols linking; count 0 → webview falls back to filesystem.
    s += "var zapp_embedded_assets* {.exportc.}: array[1, ZappEmbeddedAsset]\n";
    s += "var zapp_embedded_assets_count* {.exportc.}: cint = cint(0)\n";
    return s;
  }
  // `staticRead` requires a compile-time (const) context in Nim 2.x — calling
  // it in a `let`/`var` initializer fails ("'staticRead' can only be used in
  // compile-time context"). So read into a `const`, then bind a module-level
  // `let` copy that `unsafeAddr` can target:
  //   const a0Const = staticRead(...)  ← compile-time embed (rodata)
  //   let a0: string = a0Const         ← addressable, immutable, program-lifetime
  // `let` (not `var`) makes the buffer compiler-enforced immutable: the raw
  // `ptr uint8` we hand the .m scheme handler can never be invalidated by a
  // later reassignment. NOTE: this is a GC heap copy of the rodata bytes (≈1×
  // the compressed-asset size resident at runtime) — unlike the zc `embed`
  // path which points straight into rodata. Acceptable now; revisit if total
  // embedded-asset size grows large.
  assets.forEach((a, i) => {
    // relPath is Vite-generated (hashed, [a-zA-Z0-9_-./]) → no quote escaping
    // needed for the staticRead literal; the cstring path below escapes anyway.
    const rel = "assets" + a.relPath + (a.brotli ? ".br" : "");
    s += `const a${i}Const = staticRead("${rel}")\n`;
    s += `let a${i}: string = a${i}Const\n`;
  });
  s += `\nvar zapp_embedded_assets* {.exportc.}: array[${assets.length}, ZappEmbeddedAsset] = [\n`;
  assets.forEach((a, i) => {
    const esc = a.relPath.replace(/\\/g, "/").replace(/"/g, '\\"');
    s += `  ZappEmbeddedAsset(path: cstring"${esc}", ` +
         `data: cast[ptr uint8](unsafeAddr a${i}[0]), len: a${i}.len.cint, ` +
         `uncompressed_len: cint(${a.originalSize}), is_brotli: cint(${a.brotli ? 1 : 0})),\n`;
  });
  s += "]\n";
  s += `var zapp_embedded_assets_count* {.exportc.}: cint = cint(${assets.length})\n`;
  return s;
}

/**
 * Generate `.zapp/zapp_assets.nim` for the Nim build path.
 *
 * - opts.embed = false (dev): emits a count-0 stub so `import zapp_assets`
 *   resolves; webview falls back to filesystem (unchanged dev behaviour).
 *   Removes the marker so callers can detect "no embed".
 * - opts.embed = true (prod): walks + brotli-compresses assets (via
 *   collectAssets), renders the full table, and writes the embed marker.
 *
 * Returns the path to the generated `.zapp/zapp_assets.nim`.
 */
export async function generateAssetManifestNim(
  root: string,
  assetDir: string,
  opts: { embed: boolean; compress?: boolean },
): Promise<string> {
  const zappDir = path.join(root, ".zapp");
  await mkdir(zappDir, { recursive: true });
  const outPath = path.join(zappDir, "zapp_assets.nim");
  const markerPath = path.join(root, ASSETS_EMBEDDED_MARKER);

  if (!opts.embed) {
    // Dev: count-0 stub so `import zapp_assets` resolves; filesystem fallback.
    await Bun.write(outPath, renderAssetsNim([]));
    await rm(markerPath, { force: true }); // no embed → no marker
    return outPath;
  }

  const { assets } = await collectAssets(root, assetDir, opts.compress ?? true);
  await Bun.write(outPath, renderAssetsNim(assets));
  await Bun.write(markerPath, ""); // embed → marker

  let totalOriginal = 0;
  let totalCompressed = 0;
  for (const a of assets) {
    totalOriginal += a.originalSize;
    totalCompressed += a.compressedSize ?? a.originalSize;
  }
  clog(1,
    `compressed ${assets.length} assets: ` +
    `${Math.round(totalOriginal / 1024)} KB → ${Math.round(totalCompressed / 1024)} KB ` +
    `(${Math.round((1 - totalCompressed / totalOriginal) * 100)}% reduction)`
  );

  return outPath;
}
