#!/usr/bin/env bun
import path from "node:path";
import process from "node:process";
import { runDev } from "./dev";
import { runBuild } from "./build";
import { runInit } from "./init";
import { runPackage } from "./package";
import { runGenerate } from "./generate";

const checkPrerequisites = () => {
  const missing: string[] = [];

  if (!Bun.which("zc")) {
    missing.push(
      "  zc (Zen-C compiler) is not on PATH.\n" +
      "    Install: https://github.com/z-libs/Zen-C\n" +
      "    Then add to PATH or set ZC_ROOT."
    );
  }

  if (missing.length > 0) {
    process.stderr.write(
      "[zapp] Missing required tools:\n\n" + missing.join("\n\n") + "\n\n"
    );
    process.exit(1);
  }
};

const cwd = process.cwd();

const parseFlag = (name: string, fallback: string): string => {
  const idx = process.argv.indexOf(name);
  if (idx === -1) return fallback;
  const value = process.argv[idx + 1];
  if (!value || value.startsWith("--")) return fallback;
  return value;
};

const command = process.argv[2] ?? "help";
const root = path.resolve(cwd, parseFlag("--root", "."));
const frontendDir = path.resolve(root, parseFlag("--frontend", "."));
const buildFile = path.resolve(root, parseFlag("--input", parseFlag("--build-file", "zapp/build.zc")));
const defaultOut = process.platform === "win32" ? "zapp.exe" : "zapp";
const nativeOut = path.resolve(root, parseFlag("--out", defaultOut));
const assetDir = path.resolve(frontendDir, parseFlag("--asset-dir", "dist"));
const devUrl = parseFlag("--dev-url", "http://localhost:5173");
const withBrotli = process.argv.includes("--brotli");
const embedAssets = process.argv.includes("--embed-assets") || process.argv.includes("--bytecode");
const backendFlag = parseFlag("--backend", "");

const main = async () => {
  if (command !== "init" && command !== "help" && command !== "generate") {
    checkPrerequisites();
  }

  if (command === "init") {
    const name = parseFlag("-n", parseFlag("--name", "zapp-app"));
    const template = parseFlag("-t", parseFlag("--template", "svelte-ts"));
    const withBackend = process.argv.includes("--backend");
    await runInit({ root, name, template, withBackend });
    return;
  }
  if (command === "dev") {
    await runDev({ root, frontendDir, buildFile, nativeOut, devUrl, withBrotli, embedAssets, backendScript: backendFlag || undefined });
    return;
  }
  if (command === "build") {
    await runBuild({
      root,
      frontendDir,
      buildFile,
      nativeOut,
      assetDir,
      withBrotli,
      embedAssets,
      backendScript: backendFlag || undefined,
    });
    return;
  }
  if (command === "package") {
    await runPackage({ root, nativeOut });
    return;
  }
  if (command === "generate") {
    const outDir = parseFlag("--out-dir", "");
    await runGenerate({ root, outDir: outDir || undefined, frontendDir });
    return;
  }

  process.stdout.write(
    [
      "zapp cli",
      "",
      "Commands:",
      "  init    Scaffold a new Zapp project",
      "  dev      Run Vite + native app together (bun first)",
      "  build    Build frontend assets + native binary (bun first)",
      "  package  Package the binary into a macOS .app bundle",
      "  generate Generate TypeScript bindings from Zen-C services",
      "",
      "Common flags:",
      "  --root <path>",
      "  --frontend <path>",
      "  --input <path>       Build file (default: zapp/build.zc, alias: --build-file)",
      "  --out <path>",
      "  --dev-url <url>",
      "",
      "Optional flags:",
      "  --asset-dir <path>",
      "  --backend <path>  Backend script (default: auto-detect zapp/backend.ts)",
      "  --embed-assets    Embed all frontend assets in the binary",
      "  --brotli          Brotli-compress embedded assets (requires --embed-assets)",
      "",
    ].join("\n"),
  );
};

main().catch((error) => {
  process.stderr.write(`[zapp] ${error instanceof Error ? error.message : String(error)}\n`);
  process.exit(1);
});
