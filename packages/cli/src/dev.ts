import path from "node:path";
import process from "node:process";
import { existsSync } from "node:fs";
import { createInterface } from "node:readline";
import { mkdir } from "node:fs/promises";
import {
  ensureQjsLib,
  killChild,
  nativeIncludeArgs,
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
import type { ResolvedZappConfig } from "./config";

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
  logLevel,
  config,
}: {
  root: string;
  frontendDir: string;
  buildFile: string;
  nativeOut: string;
  devUrl: string;
  withBrotli: boolean;
  embedAssets: boolean;
  backendScript?: string;
  logLevel?: "error" | "warn" | "info" | "debug" | "trace";
  config: ResolvedZappConfig;
}) => {
  process.stdout.write(`[zapp] starting dev orchestration (${preferredJsTool()})\n`);
  if (withBrotli && !embedAssets) {
    process.stdout.write("[zapp] note: --brotli has no effect without --embed-assets\n");
  }

  await runGenerate({ root, frontendDir });

  const vite = embedAssets ? null : spawnPackageScript("dev", { cwd: frontendDir });
  let app: any = null;
  let shuttingDown = false;

  const shutdown = (reason: "user" | "app-exit" | "error" = "error") => {
    if (shuttingDown) return;
    shuttingDown = true;
    if (reason === "user") {
      process.stdout.write("\n[zapp] gracefully exiting...\n");
    } else if (reason === "app-exit") {
      process.stdout.write("[zapp] app exited, cleaning up...\n");
    }
    killChild(app);
    killChild(vite);
    setTimeout(() => process.exit(0), 1500);
  };

  process.on("SIGINT", () => shutdown("user"));
  process.on("SIGTERM", () => shutdown("user"));
  process.on("SIGHUP", () => shutdown("user"));

  if (process.platform === "win32" && process.stdin.isTTY) {
    const rl = createInterface({ input: process.stdin });
    rl.on("SIGINT", () => shutdown("user"));
    rl.on("close", () => shutdown("user"));
  }

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
      logLevel,
    });

    await mkdir(path.dirname(nativeOut), { recursive: true });
    const qjsLib = await ensureQjsLib(root, "dev");
    const zcArgs = ["build", buildFile, buildConfigFile, "-DZAPP_BUILD_DEV", "--debug", ...nativeIncludeArgs()];
    const manifest = embedAssets
      ? await buildAssetManifest({ assetDir, withBrotli })
      : { v: 1, generatedAt: new Date().toISOString(), assets: [] as any[], embedded: false };
    const assetsFile = await generateAssetsZc(root, manifest, assetDir);
    zcArgs.push(assetsFile);
    // On Windows, embed the application manifest for comctl32 v6
    if (process.platform === "win32") {
      const manifestSrc = path.join(root, "config", "windows", "app.manifest");
      if (existsSync(manifestSrc)) {
        const buildDir = path.join(root, ".zapp", "build");
        await mkdir(buildDir, { recursive: true });
        const rcPath = path.join(buildDir, "app.rc");
        await Bun.write(rcPath, `1 24 "${manifestSrc.replace(/\\/g, "/")}"\n`);
        const resPath = path.join(buildDir, "app_manifest.o");
        await runCmd("windres", [rcPath, "-O", "coff", "-o", resPath]);
        zcArgs.push(resPath);
      }
    }

    zcArgs.push("-o", nativeOut, "-L", path.dirname(qjsLib), "-lqjs");
    await runCmd("zc", zcArgs, { cwd: root, env: { ZAPP_NATIVE: resolveNativeDir() } });
    app = spawnStreaming(nativeOut, [], {
      cwd: root,
    });

    app.exited.then((code: number | null) => {
      if (!shuttingDown) {
        shutdown("app-exit");
      }
    });
    vite?.exited.then(() => {
      if (!shuttingDown) {
        shutdown("error");
      }
    });
  } catch (error) {
    shutdown("error");
    throw error;
  }

  await new Promise(() => {});
  return path.resolve(root);
};
