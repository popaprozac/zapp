import path from "node:path";
import process from "node:process";
import {
  killChild,
  preferredJsTool,
  resolveNativeDir,
  runCmd,
  runPackageScript,
  sleep,
  spawnPackageScript,
  spawnStreaming,
} from "./common";
import { buildAssetManifest, generateAssetsZc } from "./build";
import { generateBuildConfigZc } from "./build-config";
import { resolveAndBundleBackend } from "./backend";
import { runGenerate } from "./generate";

const waitForUrl = async (url: string, timeoutMs: number) => {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const res = await fetch(url);
      if (res.ok) return;
    } catch {
      await sleep(100);
    }
  }
  throw new Error(`Timed out waiting for ${url}`);
};

export const runDev = async ({
  root,
  frontendDir,
  buildFile,
  nativeOut,
  devUrl,
  withBrotli,
  embedAssets,
  backendScript,
}: {
  root: string;
  frontendDir: string;
  buildFile: string;
  nativeOut: string;
  devUrl: string;
  withBrotli: boolean;
  embedAssets: boolean;
  backendScript?: string;
}) => {
  process.stdout.write(`[zapp] starting dev orchestration (${preferredJsTool()})\n`);
  if (withBrotli && !embedAssets) {
    process.stdout.write("[zapp] note: --brotli has no effect without --embed-assets\n");
  }

  await runGenerate({ root, frontendDir });

  const vite = embedAssets ? null : spawnPackageScript("dev", { cwd: frontendDir });
  let app: any = null;
  let shuttingDown = false;

  const shutdown = () => {
    if (shuttingDown) return;
    shuttingDown = true;
    killChild(app);
    killChild(vite);
    setTimeout(() => process.exit(0), 500).unref();
  };

  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
  process.on("exit", shutdown);

  try {
    const assetDir = path.join(frontendDir, "dist");
    if (embedAssets) {
      process.stdout.write("[zapp] dev embedded mode: building static frontend assets\n");
      await runPackageScript("build", { cwd: frontendDir });
    } else {
      await waitForUrl(devUrl, 30000);
    }

    const backendScriptPath = await resolveAndBundleBackend({ root, frontendDir, backendScript });

    const buildConfigFile = await generateBuildConfigZc({
      root,
      mode: embedAssets ? "dev-embedded" : "dev",
      assetDir,
      devUrl,
      backendScriptPath,
    });

    const zcArgs = ["build", buildFile, buildConfigFile, "-DZAPP_BUILD_DEV"];
    const manifest = embedAssets
      ? await buildAssetManifest({ assetDir, withBrotli })
      : { v: 1, generatedAt: new Date().toISOString(), assets: [] as any[], embedded: false };
    const assetsFile = await generateAssetsZc(root, manifest, assetDir);
    zcArgs.push(assetsFile);
    zcArgs.push("-o", nativeOut);
    await runCmd("zc", zcArgs, { cwd: root, env: { ZAPP_NATIVE: resolveNativeDir() } });
    app = spawnStreaming(nativeOut, [], {
      cwd: root,
    });

    app.exited.then((code: number | null) => {
      process.stdout.write(`[zapp] native process exited (${code ?? "null"})\n`);
      shutdown();
    });
    vite?.exited.then((code: number | null) => {
      process.stdout.write(`[zapp] vite exited (${code ?? "null"})\n`);
      shutdown();
    });
  } catch (error) {
    shutdown();
    throw error;
  }

  await new Promise(() => {});
  return path.resolve(root);
};
