import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { brotliCompressSync, constants as zlibConstants } from "node:zlib";
import { preferredJsTool, runCmd, runPackageScript } from "./common.js";
const walkFiles = async (dir) => {
    const entries = await fs.readdir(dir, { withFileTypes: true });
    const out = [];
    for (const entry of entries) {
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) {
            out.push(...(await walkFiles(full)));
            continue;
        }
        out.push(full);
    }
    return out;
};
const maybeBrotli = async (filePath) => {
    const source = await fs.readFile(filePath);
    const compressed = brotliCompressSync(source, {
        params: {
            [zlibConstants.BROTLI_PARAM_QUALITY]: 11,
        },
    });
    const outPath = `${filePath}.br`;
    await fs.writeFile(outPath, compressed);
    return outPath;
};
const generateAssetsZc = async (root, manifest, assetDir) => {
    let zcContent = `// AUTO-GENERATED FILE. DO NOT EDIT.
import "std/string.zc";

struct EmbeddedAsset {
    path: string;
    data: u8*;
    len: int;
    is_brotli: bool;
}

`;
    const assetEntries = [];
    for (let i = 0; i < manifest.assets.length; i++) {
        const item = manifest.assets[i];
        const isBrotli = item.brotli != null;
        const filePath = isBrotli ? item.brotli.file : item.file;
        const relPathToEmbed = path.relative(root, path.join(assetDir, filePath)).replace(/\\/g, "/");
        zcContent += `let __zapp_asset_${i} = embed "${relPathToEmbed}" as u8[];\n`;
        let logicalPath = "/" + item.file.replace(/\\/g, "/");
        assetEntries.push(`    EmbeddedAsset{ path: "${logicalPath}", data: __zapp_asset_${i}.ptr, len: __zapp_asset_${i}.len as int, is_brotli: ${isBrotli ? 'true' : 'false'} }`);
    }
    zcContent += `
export let zapp_embedded_assets = [
${assetEntries.join(",\n")}
];
export let zapp_embedded_assets_count: int = ${assetEntries.length};
`;
    await fs.writeFile(path.join(root, "zapp_assets.zc"), zcContent);
};
export const runBuild = async ({ root, frontendDir, buildFile, nativeOut, assetDir, withBrotli, bytecode, }) => {
    process.stdout.write(`[zapp] building frontend assets (${preferredJsTool()})\n`);
    await runPackageScript("build", { cwd: frontendDir });
    const allFiles = await walkFiles(assetDir);
    const manifest = {
        v: 1,
        generatedAt: new Date().toISOString(),
        assets: [],
        bytecode: bytecode === true,
    };
    for (const file of allFiles) {
        const rel = path.relative(assetDir, file).split(path.sep).join("/");
        const stat = await fs.stat(file);
        const item = { file: rel, size: stat.size, brotli: null };
        if (withBrotli) {
            const brPath = await maybeBrotli(file);
            const brStat = await fs.stat(brPath);
            item.brotli = { file: `${rel}.br`, size: brStat.size };
        }
        manifest.assets.push(item);
    }
    const manifestPath = path.join(assetDir, "zapp-assets-manifest.json");
    await fs.writeFile(manifestPath, JSON.stringify(manifest, null, 2));
    await generateAssetsZc(root, manifest, assetDir);
    process.stdout.write("[zapp] building native binary\n");
    await runCmd("zc", ["build", buildFile, "-o", nativeOut], { cwd: root });
    process.stdout.write([
        "[zapp] build complete",
        `native: ${nativeOut}`,
        `assets: ${assetDir}`,
        "",
        "Run production mode (scheme loader, default):",
        `ZAPP_WEBVIEW_MODE=prod ZAPP_ASSET_DIR="${assetDir}" ZAPP_PROD_LOADER=scheme "${nativeOut}"`,
        "",
    ].join("\n"));
};
