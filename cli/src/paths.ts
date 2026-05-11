// Centralized path resolution for the Zapp CLI.
//
// The CLI needs several directories that live outside cli/ in the
// monorepo but must be bundled alongside it when published to npm.
// Each resolver checks two locations:
//   1. Monorepo layout: ../../<dir> relative to cli/src/
//   2. Published layout: ../<dir> relative to cli/src/ (i.e. cli/<dir>/)
//
// vendor/txiki.js is special — it's too large to bundle (~700 MB with
// submodules), so it's downloaded on-demand to ~/.zapp/vendor/txiki.js
// the first time a project enables the txiki worker engine.

import path from "node:path";
import os from "node:os";
import { existsSync } from "node:fs";
import { mkdir } from "node:fs/promises";

const CLI_SRC_DIR = import.meta.dir;

function resolve(name: string, sentinel: string): string {
  // Monorepo: cli/src/ → ../../<name>/
  const monorepo = path.resolve(CLI_SRC_DIR, "../..", name);
  if (existsSync(path.join(monorepo, sentinel))) return monorepo;

  // Published: cli/src/ → ../<name>/ (sibling of src/ inside the package)
  const bundled = path.resolve(CLI_SRC_DIR, "..", name);
  if (existsSync(path.join(bundled, sentinel))) return bundled;

  return "";
}

export function resolveNativeDir(): string {
  const dir = resolve("native", path.join("app", "app.zc"));
  if (dir) return dir;
  throw new Error(
    "[zapp] Cannot find native framework. Expected native/app/app.zc in:\n" +
    `  - ${path.resolve(CLI_SRC_DIR, "../../native")}  (monorepo)\n` +
    `  - ${path.resolve(CLI_SRC_DIR, "../native")}  (published)\n`
  );
}

export function resolveBootstrapDir(): string {
  const dir = resolve("bootstrap", "codegen.ts");
  if (dir) return dir;
  throw new Error(
    "[zapp] Cannot find bootstrap directory. Expected bootstrap/codegen.ts in:\n" +
    `  - ${path.resolve(CLI_SRC_DIR, "../../bootstrap")}  (monorepo)\n` +
    `  - ${path.resolve(CLI_SRC_DIR, "../bootstrap")}  (published)\n`
  );
}

export function resolveAssetsDir(): string {
  // Not fatal if missing — framework runs fine without a default icon.
  return resolve("assets", "zapp.icon") || resolve("assets", "zapp.png");
}

// Resolve which icon file to use when packaging. Priority:
//   1. macos.icon explicit path in zapp.config.ts
//   2. build/macos/icon.{icon,icns,iconset,png} (convention)
//   3. Framework default — assets/zapp.icon, falling back to zapp.png
//
// Returns "" when nothing is found (caller treats as "no icon"). The
// existing icon.ts pipeline handles all four extensions.
export function resolveAppIconPath(root: string, configIcon?: string): string {
  // 1. Explicit user override.
  if (configIcon) {
    const abs = path.isAbsolute(configIcon) ? configIcon : path.resolve(root, configIcon);
    if (existsSync(abs)) return abs;
  }

  // 2. build/macos/ convention. Order matters — .icon first because
  // it's the best macOS 26+ format, then .icns / .iconset / .png.
  const buildMac = path.join(root, "build", "macos");
  for (const name of ["icon.icon", "icon.icns", "icon.iconset", "icon.png"]) {
    const candidate = path.join(buildMac, name);
    if (existsSync(candidate)) return candidate;
  }

  // 3. Framework default.
  const frameworkAssets = resolveAssetsDir();
  if (frameworkAssets) {
    const defaultIcon = path.join(frameworkAssets, "zapp.icon");
    if (existsSync(defaultIcon)) return defaultIcon;
    const defaultPng = path.join(frameworkAssets, "zapp.png");
    if (existsSync(defaultPng)) return defaultPng;
  }

  return "";
}

export function resolveVendorDir(): string {
  // Check monorepo then published locations.
  const monorepo = path.resolve(CLI_SRC_DIR, "../../vendor");
  if (existsSync(monorepo)) return monorepo;
  const bundled = path.resolve(CLI_SRC_DIR, "../vendor");
  if (existsSync(bundled)) return bundled;
  // Create inside the user-level cache if neither exists.
  const cache = path.join(os.homedir(), ".zapp", "vendor");
  return cache;
}

// Resolve txiki.js — checks monorepo, published, then user cache.
// If not found anywhere, downloads it on-demand.
export async function resolveTxikiDir(): Promise<string> {
  // 1. Monorepo: vendor/txiki.js
  const monorepo = path.resolve(CLI_SRC_DIR, "../../vendor/txiki.js");
  if (existsSync(path.join(monorepo, "src", "tjs.h"))) return monorepo;

  // 2. Published: cli/vendor/txiki.js (won't exist — too large to bundle)
  const bundled = path.resolve(CLI_SRC_DIR, "../vendor/txiki.js");
  if (existsSync(path.join(bundled, "src", "tjs.h"))) return bundled;

  // 3. User-level cache: ~/.zapp/vendor/txiki.js
  const cacheDir = path.join(os.homedir(), ".zapp", "vendor", "txiki.js");
  if (existsSync(path.join(cacheDir, "src", "tjs.h"))) return cacheDir;

  // 4. Download on demand. Pin to a known-good commit — txiki.js's main
  // branch moves, and our native/worker/engines/txiki.c references specific
  // symbols (e.g. TJS_SetCookieJarPath) that newer commits may have renamed
  // or removed. Bumping this requires also updating txiki.c accordingly.
  const TXIKI_COMMIT = "e758e629fe5ee6e4c7fa72b904ebf9c094d9767f";
  process.stdout.write("[zapp] downloading txiki.js (first time only, this may take a minute)...\n");
  await mkdir(path.dirname(cacheDir), { recursive: true });

  // Can't use --depth 1 with a specific commit on most remotes — do a shallow
  // clone of the default branch then fetch + checkout the pinned commit.
  const clone = Bun.spawn([
    "git", "clone", "--filter=blob:none", "--no-checkout",
    "https://github.com/saghul/txiki.js.git", cacheDir,
  ], { stdout: "inherit", stderr: "inherit" });
  if (await clone.exited !== 0) {
    throw new Error("[zapp] Failed to clone txiki.js");
  }

  const checkout = Bun.spawn(["git", "checkout", TXIKI_COMMIT], {
    cwd: cacheDir, stdout: "inherit", stderr: "inherit",
  });
  if (await checkout.exited !== 0) {
    throw new Error(`[zapp] Failed to checkout txiki.js @ ${TXIKI_COMMIT}`);
  }

  const submodules = Bun.spawn(["git", "submodule", "update", "--init", "--recursive", "--depth", "1"], {
    cwd: cacheDir, stdout: "inherit", stderr: "inherit",
  });
  if (await submodules.exited !== 0) {
    throw new Error("[zapp] Failed to fetch txiki.js submodules");
  }

  // Apply local patches that haven't been upstreamed yet. The patches/
  // directory ships with the CLI package. Each patch is applied with
  // `git apply` from the txiki clone's root. This is a workaround until
  // upstream merges the equivalent API.
  const patchesDir = path.resolve(CLI_SRC_DIR, "../patches");
  if (existsSync(patchesDir)) {
    const { readdir } = await import("node:fs/promises");
    const patches = (await readdir(patchesDir)).filter(f => f.endsWith(".patch")).sort();
    for (const patch of patches) {
      const patchPath = path.join(patchesDir, patch);
      process.stdout.write(`[zapp] applying ${patch}\n`);
      const apply = Bun.spawn(["git", "apply", patchPath], {
        cwd: cacheDir, stdout: "inherit", stderr: "inherit",
      });
      if (await apply.exited !== 0) {
        throw new Error(`[zapp] Failed to apply ${patch} to txiki.js. The pinned commit may have drifted.`);
      }
    }
  }

  process.stdout.write(`[zapp] txiki.js downloaded (pinned to ${TXIKI_COMMIT.slice(0, 7)})\n`);
  return cacheDir;
}

// Resolve Bare runtime — same monorepo/published/cache fall-through
// as txiki. Bare is much smaller than txiki (~5 MB clone) but cmake-fetch
// pulls in libjs + libjsc + libuv + boringssl during configure, so the
// total disk footprint is similar. Pin matches `vendor/bare`'s submodule
// SHA so on-demand clones reproduce the same source.
export async function resolveBareDir(): Promise<string> {
  // 1. Monorepo: vendor/bare (submodule)
  const monorepo = path.resolve(CLI_SRC_DIR, "../../vendor/bare");
  if (existsSync(path.join(monorepo, "include", "bare.h"))) return monorepo;

  // 2. Published: cli/vendor/bare (won't normally exist — submodule
  // contents aren't part of the cli npm publish; cache below handles it)
  const bundled = path.resolve(CLI_SRC_DIR, "../vendor/bare");
  if (existsSync(path.join(bundled, "include", "bare.h"))) return bundled;

  // 3. User-level cache
  const cacheDir = path.join(os.homedir(), ".zapp", "vendor", "bare");
  if (existsSync(path.join(cacheDir, "include", "bare.h"))) return cacheDir;

  // 4. Download on demand. Pin matches the spike-branch submodule SHA;
  // Bare's API surface is fairly stable across patch releases but their
  // engine sub-modules (libjs/libjsc) drift more, so the libjs commit
  // pin is the load-bearing version lock.
  const BARE_COMMIT = "bfbc127"; // v1.28.5
  process.stdout.write("[zapp] downloading Bare runtime (first time only)...\n");
  await mkdir(path.dirname(cacheDir), { recursive: true });

  const clone = Bun.spawn([
    "git", "clone", "--filter=blob:none", "--no-checkout",
    "https://github.com/holepunchto/bare.git", cacheDir,
  ], { stdout: "inherit", stderr: "inherit" });
  if (await clone.exited !== 0) throw new Error("[zapp] Failed to clone Bare");

  const checkout = Bun.spawn(["git", "checkout", BARE_COMMIT], {
    cwd: cacheDir, stdout: "inherit", stderr: "inherit",
  });
  if (await checkout.exited !== 0) {
    throw new Error(`[zapp] Failed to checkout Bare @ ${BARE_COMMIT}`);
  }

  process.stdout.write(`[zapp] Bare downloaded (pinned to ${BARE_COMMIT})\n`);
  return cacheDir;
}
