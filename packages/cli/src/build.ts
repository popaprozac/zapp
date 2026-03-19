import path from "node:path";
import process from "node:process";
import { mkdir } from "node:fs/promises";
import { brotliCompressSync, constants as zlibConstants } from "node:zlib";
import { generateBuildConfigZc } from "./build-config";
import { ensureQjsLib, nativeIncludeArgs, preferredJsTool, resolveNativeDir, runCmd, runPackageScript } from "./common";
import { resolveAndBundleBackend } from "./backend";
import { runGenerate } from "./generate";
import type { ResolvedZappConfig } from "./config";

export const walkFiles = async (dir: string): Promise<string[]> => {
  const glob = new Bun.Glob("**/*");
  const files: string[] = [];
  for await (const file of glob.scan({ cwd: dir, absolute: true })) {
    const stat = Bun.file(file);
    if (stat.size > 0 || (await stat.exists())) {
        files.push(file);
    }
  }
  return files;
};

export const maybeBrotli = async (filePath: string): Promise<string> => {
  const source = await Bun.file(filePath).arrayBuffer();
  const compressed = brotliCompressSync(new Uint8Array(source), {
    params: {
      [zlibConstants.BROTLI_PARAM_QUALITY]: 11,
    },
  });
  const outPath = `${filePath}.br`;
  await Bun.write(outPath, compressed);
  return outPath;
};

export const generateAssetsZc = async (root: string, manifest: any, assetDir: string) => {
  let zcContent = `// AUTO-GENERATED FILE. DO NOT EDIT.

`;

  // If no assets, generate empty placeholder
  if (!manifest.assets || manifest.assets.length === 0) {
    zcContent += `
raw {
    struct ZappEmbeddedAsset zapp_embedded_assets[1];
    int zapp_embedded_assets_count = 0;
}
`;
    const buildDir = path.join(root, ".zapp");
    await mkdir(buildDir, { recursive: true });
    const outPath = path.join(buildDir, "zapp_assets.zc");
    await Bun.write(outPath, zcContent);
    return outPath;
  }

  const assetEntries = [];
  const assetExterns = [];
  for (let i = 0; i < manifest.assets.length; i++) {
    const item = manifest.assets[i];
    const isBrotli = item.brotli != null;
    const filePath = isBrotli ? item.brotli.file : item.file;
    const absPathToEmbed = path.join(assetDir, filePath).replace(/\\/g, "/");
    
    zcContent += `let __zapp_asset_${i} = embed "${absPathToEmbed}" as u8[];\n`;
    
    let logicalPath = "/" + item.file.replace(/\\/g, "/");
    assetExterns.push(`    extern Slice_uint8_t __zapp_asset_${i};`);
    assetEntries.push(`        zapp_embedded_assets[${i}].path = "${logicalPath}";`);
    assetEntries.push(`        zapp_embedded_assets[${i}].data = __zapp_asset_${i}.data;`);
    assetEntries.push(`        zapp_embedded_assets[${i}].len = __zapp_asset_${i}.len;`);
    assetEntries.push(`        zapp_embedded_assets[${i}].uncompressed_len = ${item.size};`);
    assetEntries.push(`        zapp_embedded_assets[${i}].is_brotli = ${isBrotli ? 'true' : 'false'};`);
  }

    zcContent += `
raw {
${assetExterns.join("\n")}
    struct ZappEmbeddedAsset zapp_embedded_assets[${manifest.assets.length || 1}];
    int zapp_embedded_assets_count = ${manifest.assets.length};

    __attribute__((constructor))
    static void init_zapp_assets(void) {
${assetEntries.join("\n")}
    }
}
`;

  const buildDir = path.join(root, ".zapp");
  await mkdir(buildDir, { recursive: true });
  const outPath = path.join(buildDir, "zapp_assets.zc");
  await Bun.write(outPath, zcContent);
  return outPath;
};

const collectWorkerStems = async (assetDir: string): Promise<Set<string>> => {
  const stems = new Set<string>();
  const manifestPath = path.join(assetDir, "zapp-workers", "manifest.json");
  try {
    const raw = await Bun.file(manifestPath).text();
    const data = JSON.parse(raw);
    const workers = data.workers ?? data;
    for (const key of Object.keys(workers)) {
      const stem = path.basename(key).replace(/\.[^.]+$/, "");
      if (stem) stems.add(stem);
    }
  } catch { /* no manifest */ }
  return stems;
};

export const buildAssetManifest = async ({
  assetDir,
  withBrotli,
}: {
  assetDir: string;
  withBrotli: boolean;
}) => {
  const allFiles = await walkFiles(assetDir);
  const workerStems = withBrotli ? await collectWorkerStems(assetDir) : new Set<string>();
  const manifest = {
    v: 1,
    generatedAt: new Date().toISOString(),
    assets: [] as any[],
    embedded: true,
  };

  for (const file of allFiles) {
    const rel = path.relative(assetDir, file).split(path.sep).join("/");
    const stat = Bun.file(file);
    const item: any = { file: rel, size: stat.size, brotli: null };

    let skipBrotli = false;
    if (rel.startsWith("zapp-workers/")) {
      skipBrotli = true;
    } else if (rel.startsWith("assets/") && workerStems.size > 0) {
      const baseName = path.basename(rel).replace(/\.[^.]+$/, "");
      for (const stem of workerStems) {
        if (baseName === stem || baseName.startsWith(`${stem}-`)) {
          skipBrotli = true;
          break;
        }
      }
    }

    if (withBrotli && !skipBrotli) {
      const brPath = await maybeBrotli(file);
      const brStat = Bun.file(brPath);
      item.brotli = { file: `${rel}.br`, size: brStat.size };
    }
    manifest.assets.push(item);
  }

  return manifest;
};

export const runBuild = async ({
  root,
  frontendDir,
  buildFile,
  nativeOut,
  assetDir,
  withBrotli,
  embedAssets,
  isDebug,
  backendScript,
  logLevel,
  config,
}: {
  root: string;
  frontendDir: string;
  buildFile: string;
  nativeOut: string;
  assetDir: string;
  withBrotli: boolean;
  embedAssets: boolean;
  isDebug: boolean;
  backendScript?: string;
  logLevel?: "error" | "warn" | "info" | "debug" | "trace";
  config: ResolvedZappConfig;
}) => {
  if (withBrotli && !embedAssets) {
    process.stdout.write("[zapp] note: --brotli has no effect without embedded assets\n");
  }

  await runGenerate({ root, frontendDir });

  process.stdout.write(`[zapp] building frontend assets (${preferredJsTool()})\n`);
  await runPackageScript("build", { cwd: frontendDir });

  const manifest = embedAssets
    ? await buildAssetManifest({ assetDir, withBrotli })
    : { v: 1, generatedAt: new Date().toISOString(), assets: [] as any[], embedded: false };

  if (embedAssets) {
    const manifestPath = path.join(assetDir, "zapp-assets-manifest.json");
    await Bun.write(manifestPath, JSON.stringify(manifest, null, 2));
  }

  const backendScriptPath = await resolveAndBundleBackend({ root, frontendDir, backendScript });
  const buildMode = isDebug ? "prod" : (embedAssets ? "prod-embedded" : "prod");
  const effectiveLogLevel = logLevel ?? (isDebug ? "debug" : "warn");
  const buildConfigFile = await generateBuildConfigZc({
    root,
    mode: buildMode,
    assetDir,
    backendScriptPath,
    logLevel: effectiveLogLevel,
  });

  process.stdout.write("[zapp] building native binary\n");
  await mkdir(path.dirname(nativeOut), { recursive: true });
  const qjsLib = await ensureQjsLib(root, isDebug ? "dev" : "release");
  const zcArgs = ["build", buildFile, buildConfigFile, ...nativeIncludeArgs()];
  
  // Always generate assets file (provides empty placeholder when not embedding)
  const assetsFile = await generateAssetsZc(root, manifest, assetDir);
  if (await Bun.file(assetsFile).exists()) zcArgs.push(assetsFile);
  
  // Add debug flags if isDebug, otherwise optimize for size
  if (isDebug) {
    zcArgs.push("--debug");
  } else {
    zcArgs.push("-Oz");  // Aggressive size optimization
    zcArgs.push("-flto"); // Link-time optimization
  }
  
  zcArgs.push("-o", nativeOut, "-L", path.dirname(qjsLib), "-lqjs");
  await runCmd("zc", zcArgs, { cwd: root, env: { ZAPP_NATIVE: resolveNativeDir() } });

  // Strip symbols in release builds for smaller binary
  if (!isDebug) {
    try {
      const stripPath = Bun.which("strip");
      if (stripPath) {
        await runCmd("strip", [nativeOut]);
      }
    } catch (e) {
      process.stdout.write(`[zapp] warning: strip failed: ${e}\n`);
    }
  }

  process.stdout.write(
    [
      "[zapp] build complete",
      `native: ${nativeOut}`,
      `mode: ${isDebug ? 'debug' : buildMode}`,
      "",
      "Run:",
      `${nativeOut}`,
      "",
    ].join("\n"),
  );
};
