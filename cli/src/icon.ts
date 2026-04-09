// Icon processing — converts PNG/ICNS/iconset to the appropriate bundle format.
// PNG → asset catalog (actool) → Assets.car for liquid glass (macOS 26+)
// ICNS → direct copy (traditional)
// iconset → iconutil → ICNS

import path from "node:path";
import { mkdir, rm } from "node:fs/promises";
import { existsSync } from "node:fs";

export interface IconResult {
  /** "assetcatalog" (PNG → Assets.car) or "icns" (direct .icns) */
  type: "assetcatalog" | "icns";
  /** Files to copy into Contents/Resources/ */
  files: Array<{ src: string; dest: string }>;
  /** Info.plist key to add */
  plistKey: "CFBundleIconName" | "CFBundleIconFile";
  /** Info.plist value */
  plistValue: string;
}

/**
 * Process an icon source into bundle-ready format.
 * @param iconPath Path to .png, .icns, or .iconset
 * @param tempDir Temp directory for intermediate files
 */
export async function processIcon(iconPath: string, tempDir: string): Promise<IconResult> {
  const ext = path.extname(iconPath).toLowerCase();

  // .icon directory (macOS 26+ Icon Composer format)
  if (ext === ".icon") {
    const files: Array<{ src: string; dest: string }> = [
      { src: iconPath, dest: "AppIcon.icon" },
    ];

    // Also generate .icns fallback from the framework PNG for older macOS
    const siblingPng = path.join(path.dirname(iconPath), path.basename(iconPath, ".icon") + ".png");
    if (existsSync(siblingPng)) {
      try {
        const fallback = await fallbackPngToIcns(siblingPng, tempDir);
        files.push(...fallback.files);
      } catch {}
    }

    return {
      type: "assetcatalog",
      files,
      plistKey: "CFBundleIconName",
      plistValue: "AppIcon",
    };
  }

  if (ext === ".icns") {
    return {
      type: "icns",
      files: [{ src: iconPath, dest: path.basename(iconPath) }],
      plistKey: "CFBundleIconFile",
      plistValue: path.basename(iconPath, ".icns"),
    };
  }

  if (ext === ".iconset") {
    // Convert .iconset → .icns via iconutil
    const icnsPath = path.join(tempDir, "AppIcon.icns");
    const proc = Bun.spawn(["iconutil", "--convert", "icns", "--output", icnsPath, iconPath], {
      stdout: "pipe",
      stderr: "pipe",
    });
    const exitCode = await proc.exited;
    if (exitCode !== 0) {
      const stderr = await new Response(proc.stderr).text();
      throw new Error(`[zapp] iconutil failed: ${stderr}`);
    }
    return {
      type: "icns",
      files: [{ src: icnsPath, dest: "AppIcon.icns" }],
      plistKey: "CFBundleIconFile",
      plistValue: "AppIcon",
    };
  }

  if (ext === ".png") {
    // PNG → asset catalog → actool → Assets.car
    // This enables liquid glass on macOS 26+ and standard icon on older versions
    return await buildAssetCatalog(iconPath, tempDir);
  }

  throw new Error(`[zapp] unsupported icon format: ${ext} (use .png, .icns, or .iconset)`);
}

async function buildAssetCatalog(pngPath: string, tempDir: string): Promise<IconResult> {
  const xcassetsDir = path.join(tempDir, "Assets.xcassets");
  const iconsetDir = path.join(xcassetsDir, "AppIcon.appiconset");
  await mkdir(iconsetDir, { recursive: true });

  // Copy the PNG
  const iconDest = path.join(iconsetDir, "icon_1024x1024.png");
  await Bun.write(iconDest, Bun.file(pngPath));

  // Write Contents.json for the icon set
  // macOS requires specific size/scale combinations for actool to generate Assets.car
  const contentsJson = {
    images: [
      { filename: "icon_1024x1024.png", idiom: "mac", scale: "1x", size: "16x16" },
      { filename: "icon_1024x1024.png", idiom: "mac", scale: "2x", size: "16x16" },
      { filename: "icon_1024x1024.png", idiom: "mac", scale: "1x", size: "32x32" },
      { filename: "icon_1024x1024.png", idiom: "mac", scale: "2x", size: "32x32" },
      { filename: "icon_1024x1024.png", idiom: "mac", scale: "1x", size: "128x128" },
      { filename: "icon_1024x1024.png", idiom: "mac", scale: "2x", size: "128x128" },
      { filename: "icon_1024x1024.png", idiom: "mac", scale: "1x", size: "256x256" },
      { filename: "icon_1024x1024.png", idiom: "mac", scale: "2x", size: "256x256" },
      { filename: "icon_1024x1024.png", idiom: "mac", scale: "1x", size: "512x512" },
      { filename: "icon_1024x1024.png", idiom: "mac", scale: "2x", size: "512x512" },
    ],
    info: {
      author: "xcode",
      version: 1,
    },
  };
  await Bun.write(path.join(iconsetDir, "Contents.json"), JSON.stringify(contentsJson, null, 2));

  // Write root Contents.json for the asset catalog
  await Bun.write(
    path.join(xcassetsDir, "Contents.json"),
    JSON.stringify({ info: { author: "xcode", version: 1 } }, null, 2)
  );

  // Compile with actool
  const outputDir = path.join(tempDir, "actool-output");
  await mkdir(outputDir, { recursive: true });

  const proc = Bun.spawn(
    [
      "xcrun", "actool",
      xcassetsDir,
      "--compile", outputDir,
      "--platform", "macosx",
      "--minimum-deployment-target", "12.0",
      "--app-icon", "AppIcon",
      "--output-partial-info-plist", path.join(tempDir, "actool-info.plist"),
    ],
    { stdout: "pipe", stderr: "pipe" }
  );

  const exitCode = await proc.exited;
  if (exitCode !== 0) {
    const stderr = await new Response(proc.stderr).text();
    process.stderr.write(`[zapp] actool warning: ${stderr}\n`);
    // Fallback: try iconutil approach (create .iconset from PNG, then .icns)
    return await fallbackPngToIcns(pngPath, tempDir);
  }

  // Collect generated files (actool produces Assets.car + AppIcon.icns)
  const carPath = path.join(outputDir, "Assets.car");
  const icnsPath = path.join(outputDir, "AppIcon.icns");

  if (!existsSync(carPath) && !existsSync(icnsPath)) {
    return await fallbackPngToIcns(pngPath, tempDir);
  }

  const files: Array<{ src: string; dest: string }> = [];
  if (existsSync(carPath)) files.push({ src: carPath, dest: "Assets.car" });
  if (existsSync(icnsPath)) files.push({ src: icnsPath, dest: "AppIcon.icns" });

  // Use CFBundleIconName for asset catalog (enables liquid glass on macOS 26+)
  // Also include .icns as fallback for older macOS
  return {
    type: "assetcatalog",
    files,
    plistKey: "CFBundleIconName",
    plistValue: "AppIcon",
  };
}

/** Fallback: convert a single PNG to .icns via iconutil (generates all sizes with sips) */
async function fallbackPngToIcns(pngPath: string, tempDir: string): Promise<IconResult> {
  const iconsetDir = path.join(tempDir, "AppIcon.iconset");
  await mkdir(iconsetDir, { recursive: true });

  // Generate required sizes from the source PNG using sips
  const sizes = [
    { name: "icon_16x16.png", size: 16 },
    { name: "icon_16x16@2x.png", size: 32 },
    { name: "icon_32x32.png", size: 32 },
    { name: "icon_32x32@2x.png", size: 64 },
    { name: "icon_128x128.png", size: 128 },
    { name: "icon_128x128@2x.png", size: 256 },
    { name: "icon_256x256.png", size: 256 },
    { name: "icon_256x256@2x.png", size: 512 },
    { name: "icon_512x512.png", size: 512 },
    { name: "icon_512x512@2x.png", size: 1024 },
  ];

  for (const { name, size } of sizes) {
    const outPath = path.join(iconsetDir, name);
    const proc = Bun.spawn(
      ["sips", "-z", String(size), String(size), pngPath, "--out", outPath],
      { stdout: "pipe", stderr: "pipe" }
    );
    await proc.exited;
  }

  // Convert .iconset to .icns
  const icnsPath = path.join(tempDir, "AppIcon.icns");
  const proc = Bun.spawn(["iconutil", "--convert", "icns", "--output", icnsPath, iconsetDir], {
    stdout: "pipe",
    stderr: "pipe",
  });
  const exitCode = await proc.exited;
  if (exitCode !== 0) {
    const stderr = await new Response(proc.stderr).text();
    throw new Error(`[zapp] iconutil failed: ${stderr}`);
  }

  return {
    type: "icns",
    files: [{ src: icnsPath, dest: "AppIcon.icns" }],
    plistKey: "CFBundleIconFile",
    plistValue: "AppIcon",
  };
}
