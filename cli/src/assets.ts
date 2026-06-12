// Asset embedding — brotli-compresses Vite output and generates Zen-C embed directives.
// Assets are compiled directly into the binary. Decompressed at runtime in the scheme handler.

import path from "node:path";
import { mkdir, readdir, stat } from "node:fs/promises";
import { existsSync } from "node:fs";
import { brotliCompressSync, constants } from "node:zlib";
import { clog } from "./log";

interface AssetEntry {
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

  // Collect all files from Vite dist/ output (includes _workers/ from Vite plugin)
  const files = await walkDir(distDir);
  const assets: AssetEntry[] = [];
  let totalOriginal = 0;
  let totalCompressed = 0;

  for (const file of files) {
    const relPath = "/" + path.relative(distDir, file).replace(/\\/g, "/");
    const source = await Bun.file(file).arrayBuffer();
    const compressed = brotliCompressSync(new Uint8Array(source), {
      params: { [constants.BROTLI_PARAM_QUALITY]: 11 },
    });

    // Write compressed file
    const brRelPath = relPath + ".br";
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
    zc += `        zapp_embedded_assets[${i}].is_brotli = 1;\n`;
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
