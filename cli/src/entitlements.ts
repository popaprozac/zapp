// Entitlements generator — merges `macos.entitlements` map + optional
// entitlements file into a single .plist. Written to .zapp/Entitlements.plist
// and passed to `codesign --entitlements` during dev + package.
//
// Merge rules:
//  - Typed map keys override file keys. CLI warns on overrides.
//  - If only the map is set, the plist is generated from the map alone.
//  - If only the file is set, it is copied verbatim (wrapping it in
//    <plist>/<dict> if needed).
//  - If neither is set, no file is written and `resolveEntitlements`
//    returns `{ path: "", used: false }`.

import path from "node:path";
import { existsSync } from "node:fs";
import { mkdir } from "node:fs/promises";
import type { MacOSConfig, ResolvedConfig } from "./config";

export function xmlEscape(str: string): string {
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

export function renderValue(v: string | number | boolean | string[]): string {
  if (typeof v === "boolean") return v ? "<true/>" : "<false/>";
  if (typeof v === "number") {
    return Number.isInteger(v)
      ? `<integer>${v}</integer>`
      : `<real>${v}</real>`;
  }
  if (Array.isArray(v)) {
    const items = v.map(s => `        <string>${xmlEscape(s)}</string>`).join("\n");
    return `<array>\n${items}\n    </array>`;
  }
  return `<string>${xmlEscape(v)}</string>`;
}

function extractKeys(content: string): string[] {
  const matches = content.match(/<key>([^<]+)<\/key>/g) ?? [];
  return matches.map(m => m.replace(/<\/?key>/g, ""));
}

// Strip <?xml ... ?>, <plist>, <dict>, and </plist>/</dict> wrappers so we
// keep just the key/value pairs. User files typically have the full wrapper
// (they come from Xcode or hand-written templates).
function unwrapPlistDict(content: string): string {
  let body = content;
  body = body.replace(/<\?xml[^>]*\?>\s*/, "");
  body = body.replace(/<!DOCTYPE[^>]*>\s*/, "");
  body = body.replace(/<plist[^>]*>\s*/, "");
  body = body.replace(/<\/plist>\s*$/, "");
  body = body.replace(/<dict>\s*/, "");
  body = body.replace(/<\/dict>\s*$/, "");
  return body.trim();
}

export interface ResolvedEntitlements {
  /** Absolute path to the generated file, or "" when nothing needs to be written. */
  path: string;
  /** True when entitlements are configured and codesign should pass --entitlements. */
  used: boolean;
}

export async function resolveEntitlements(
  root: string,
  config: ResolvedConfig,
): Promise<ResolvedEntitlements> {
  const macosConfig: MacOSConfig = config.macos ?? {};

  // Auto-merge `com.apple.security.cs.allow-jit` when this project links
  // a JSC-class worker engine (jsc or bare-jsc). Without the entitlement,
  // Apple Silicon's MAP_JIT enforcement keeps JSC in interpreter mode
  // (~12× slower on JIT-friendly workloads). User can opt out by
  // explicitly setting `"com.apple.security.cs.allow-jit": false` in the
  // entitlements map.
  const { hasJscClassWorkerEngine } = await import("./native");
  const needsJit = await hasJscClassWorkerEngine(root);
  const mapEntries: Record<string, string | number | boolean | string[]> =
    { ...(macosConfig.entitlements ?? {}) };
  if (needsJit && !("com.apple.security.cs.allow-jit" in mapEntries)) {
    mapEntries["com.apple.security.cs.allow-jit"] = true;
  }
  const mapKeys = Object.keys(mapEntries);

  // Resolve entitlements file. Explicit path wins; otherwise look for the
  // convention location under build/macos/.
  const filePath = macosConfig.entitlementsFile
    ? (path.isAbsolute(macosConfig.entitlementsFile)
        ? macosConfig.entitlementsFile
        : path.resolve(root, macosConfig.entitlementsFile))
    : path.join(root, "build", "macos", "app.entitlements");

  const fileExists = existsSync(filePath);
  const fileContent = fileExists ? await Bun.file(filePath).text() : "";

  if (mapKeys.length === 0 && !fileExists) {
    return { path: "", used: false };
  }

  // Warn on key overlap between file and map.
  if (fileExists && mapKeys.length > 0) {
    const fileKeys = new Set(extractKeys(fileContent));
    for (const k of mapKeys) {
      if (fileKeys.has(k)) {
        process.stderr.write(
          `[zapp] entitlements: key "${k}" defined in both ${path.relative(root, filePath)} and zapp.config.ts — config value wins\n`
        );
      }
    }
  }

  // Warn on mismatch with signing identity (ad-hoc silently ignores many
  // entitlements; users should know).
  const signing = macosConfig.signingIdentity;
  const isAdhoc = !signing || signing === "-";
  if (isAdhoc && mapKeys.length > 0) {
    const privileged = mapKeys.filter(k =>
      k.startsWith("com.apple.developer.") ||
      k === "com.apple.security.app-sandbox"
    );
    if (privileged.length > 0) {
      process.stderr.write(
        `[zapp] entitlements: ad-hoc signing ignores privileged entitlements (${privileged.join(", ")}). Set macos.signingIdentity to activate them.\n`
      );
    }
  }

  // Build the inner <dict> body. Start with the file's contents (less the
  // wrappers), then append map entries. If a key appears in both, the map
  // entry replaces the file entry via a line-level filter.
  const mapOverrides = new Set(mapKeys);
  const fileBody = fileExists
    ? unwrapPlistDict(fileContent)
        .split("\n")
        .filter((_, i, arr) => {
          // Drop file-supplied key+value pairs whose key is also in the map.
          // Walk pairs: find <key>X</key> lines and skip the matching value.
          const line = arr[i];
          const prev = i > 0 ? arr[i - 1] : "";
          const keyMatch = line.match(/<key>([^<]+)<\/key>/);
          if (keyMatch && mapOverrides.has(keyMatch[1])) return false;
          // Drop the value line that follows an overridden key.
          const prevKey = prev.match(/<key>([^<]+)<\/key>/);
          if (prevKey && mapOverrides.has(prevKey[1])) return false;
          return true;
        })
        .join("\n")
        .trim()
    : "";

  const mapBody = mapKeys
    .map(k => `    <key>${xmlEscape(k)}</key>\n    ${renderValue(mapEntries[k])}`)
    .join("\n");

  const body = [fileBody, mapBody].filter(s => s.length > 0).join("\n");

  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
${body}
</dict>
</plist>
`;

  const outPath = path.join(root, ".zapp", "Entitlements.plist");
  await mkdir(path.dirname(outPath), { recursive: true });
  await Bun.write(outPath, plist);

  return { path: outPath, used: true };
}
