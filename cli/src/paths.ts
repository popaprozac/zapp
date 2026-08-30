// Centralized path resolution for the Zapp CLI.
//
// The CLI needs several directories that live outside cli/ in the
// monorepo but must be bundled alongside it when published to npm.
// Each resolver checks two locations:
//   1. Monorepo layout: ../../<dir> relative to cli/src/
//   2. Published layout: ../<dir> relative to cli/src/ (i.e. cli/<dir>/)

import path from "node:path";
import os from "node:os";
import { existsSync } from "node:fs";
import { mkdir } from "node:fs/promises";
import { clog } from "./log";

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

// Resolve which icon file to use when packaging. Priority:
//   1. macos.icon explicit path in zapp.config.ts
//   2. build/macos/icon.{icon,icns,iconset,png} (convention)
//
// Returns "" when nothing is found (caller treats as "no icon"). Zapp does
// not impose framework branding on applications that omit an icon.
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

  return "";
}

/**
 * Resolve a 1024×1024 PNG source for the iOS app icon. iOS asset catalogs
 * require a PNG, so non-PNG sources (.icns/.icon/.iconset) are skipped.
 * Precedence: config.ios.icon (.png) → build/ios/icon.png → build/icon.png →
 * config.macos.icon (.png, reuse) → build/macos/icon.png.
 * Returns "" if no PNG is found.
 */
export function resolveIOSIconPng(
  root: string,
  config: { ios?: { icon?: string }; macos?: { icon?: string } },
): string {
  const absExistsPng = (p: string): string | "" => {
    const abs = path.isAbsolute(p) ? p : path.resolve(root, p);
    return abs.toLowerCase().endsWith(".png") && existsSync(abs) ? abs : "";
  };

  if (config.ios?.icon) { const p = absExistsPng(config.ios.icon); if (p) return p; }
  const buildIos = path.join(root, "build", "ios", "icon.png");
  if (existsSync(buildIos)) return buildIos;
  const buildRoot = path.join(root, "build", "icon.png");
  if (existsSync(buildRoot)) return buildRoot;
  if (config.macos?.icon) { const p = absExistsPng(config.macos.icon); if (p) return p; }
  const buildMac = path.join(root, "build", "macos", "icon.png");
  if (existsSync(buildMac)) return buildMac;
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

// Resolve Bare runtime — checks monorepo/published/cache fall-through.
// Bare is small (~5 MB clone) but cmake-fetch
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
  clog(0, "downloading Bare runtime (first time only)...");
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

  clog(0, `Bare downloaded (pinned to ${BARE_COMMIT})`);
  return cacheDir;
}
