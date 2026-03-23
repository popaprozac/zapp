import { mkdir, rm } from "node:fs/promises";
import path from "node:path";
import { existsSync } from "node:fs";
import { runCmd } from "./common";

/**
 * macOS icon sizes for iconset.
 * Each entry: [size, scale] → produces icon_{size}x{size}{@{scale}x}.png
 */
const ICNS_SIZES: [number, number][] = [
  [16, 1], [16, 2],
  [32, 1], [32, 2],
  [128, 1], [128, 2],
  [256, 1], [256, 2],
  [512, 1], [512, 2],
];

/**
 * Generate .icns from a PNG source using sips + iconutil (macOS only).
 */
export async function generateIcns(pngPath: string, outputDir: string): Promise<string | null> {
  if (process.platform !== "darwin") return null;
  if (!existsSync(pngPath)) {
    console.warn(`[zapp] icon source not found: ${pngPath}`);
    return null;
  }

  const iconsetDir = path.join(outputDir, "AppIcon.iconset");
  await mkdir(iconsetDir, { recursive: true });

  // Generate all required sizes
  for (const [size, scale] of ICNS_SIZES) {
    const pixels = size * scale;
    const suffix = scale > 1 ? `@${scale}x` : "";
    const filename = `icon_${size}x${size}${suffix}.png`;
    const outPath = path.join(iconsetDir, filename);
    try {
      await runCmd("sips", ["-z", String(pixels), String(pixels), pngPath, "--out", outPath]);
    } catch (err) {
      console.warn(`[zapp] failed to resize icon to ${pixels}x${pixels}: ${err}`);
      return null;
    }
  }

  // Convert iconset to icns
  const icnsPath = path.join(outputDir, "AppIcon.icns");
  try {
    await runCmd("iconutil", ["-c", "icns", iconsetDir, "-o", icnsPath]);
  } catch (err) {
    console.warn(`[zapp] iconutil failed: ${err}`);
    return null;
  }

  // Clean up iconset folder
  await rm(iconsetDir, { recursive: true, force: true });

  return icnsPath;
}

/**
 * Compile a .icon folder (macOS Tahoe liquid glass) to Assets.car using actool.
 * Requires Xcode 26 command line tools.
 */
export async function compileIconAsset(iconFolder: string, outputDir: string): Promise<string | null> {
  if (process.platform !== "darwin") return null;
  if (!existsSync(iconFolder)) {
    console.warn(`[zapp] .icon folder not found: ${iconFolder}`);
    return null;
  }

  try {
    await runCmd("actool", [
      "--compile", outputDir,
      "--platform", "macosx",
      "--minimum-deployment-target", "26.0",
      iconFolder,
    ]);
    const carPath = path.join(outputDir, "Assets.car");
    if (existsSync(carPath)) {
      return carPath;
    }
    console.warn("[zapp] actool did not produce Assets.car");
    return null;
  } catch (err) {
    console.warn(`[zapp] actool failed (requires Xcode 26): ${err}`);
    return null;
  }
}

/**
 * Generate .ico from a PNG source for Windows.
 * Tries ImageMagick first, falls back to a basic single-size copy.
 */
export async function generateIco(pngPath: string, outputPath: string): Promise<string | null> {
  if (!existsSync(pngPath)) {
    console.warn(`[zapp] icon source not found: ${pngPath}`);
    return null;
  }

  // Try ImageMagick (magick or convert)
  for (const cmd of ["magick", "convert"]) {
    try {
      await runCmd(cmd, [
        pngPath,
        "-define", "icon:auto-resize=256,128,64,48,32,16",
        outputPath,
      ]);
      if (existsSync(outputPath)) return outputPath;
    } catch {
      // Try next command
    }
  }

  console.warn("[zapp] ImageMagick not found — cannot generate .ico. Install ImageMagick for Windows icon support.");
  return null;
}
