import path from "node:path";
import { readFile } from "node:fs/promises";
import type { WebviewInjectProfile } from "./config";

export const WEBVIEW_INJECT_STYLE = 0;
export const WEBVIEW_INJECT_DOCUMENT_START = 1;
export const WEBVIEW_INJECT_DOCUMENT_END = 2;

export interface BuiltWebviewInjection {
  profile: string;
  phase: 0 | 1 | 2;
  sourcePath: string;
  source: string;
}

const scriptExtensions = new Set([
  ".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".mts", ".cts",
]);

async function readStyle(root: string, profile: string, sourcePath: string) {
  if (path.extname(sourcePath).toLowerCase() !== ".css") {
    throw new Error(
      `[zapp] webview.inject.${profile}.styles entry ${JSON.stringify(sourcePath)} ` +
      "must be a .css file",
    );
  }
  try {
    return await readFile(path.resolve(root, sourcePath), "utf8");
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    throw new Error(
      `[zapp] could not read webview.inject.${profile} style ` +
      `${JSON.stringify(sourcePath)}: ${detail}`,
    );
  }
}

async function bundleScript(
  root: string,
  profile: string,
  phase: "documentStart" | "documentEnd",
  sourcePath: string,
  optimize: boolean,
): Promise<string> {
  if (!scriptExtensions.has(path.extname(sourcePath).toLowerCase())) {
    throw new Error(
      `[zapp] webview.inject.${profile}.${phase} entry ${JSON.stringify(sourcePath)} ` +
      "must be a JavaScript or TypeScript file",
    );
  }
  const absolute = path.resolve(root, sourcePath);
  const result = await Bun.build({
    entrypoints: [absolute],
    target: "browser",
    format: "iife",
    minify: optimize,
  });
  if (!result.success || result.outputs.length !== 1) {
    const details = result.logs.map((log) => log.message).join("\n");
    throw new Error(
      `[zapp] could not bundle webview.inject.${profile}.${phase} ` +
      `${JSON.stringify(sourcePath)}${details ? `:\n${details}` : ""}`,
    );
  }
  return await result.outputs[0].text();
}

export async function buildWebviewInjections(
  root: string,
  catalog: Record<string, WebviewInjectProfile> | undefined,
  optimize: boolean,
): Promise<BuiltWebviewInjection[]> {
  if (catalog === undefined) return [];
  const entries: BuiltWebviewInjection[] = [];
  for (const [profile, definition] of Object.entries(catalog)) {
    for (const sourcePath of definition.styles ?? []) {
      entries.push({
        profile,
        phase: WEBVIEW_INJECT_STYLE,
        sourcePath,
        source: await readStyle(root, profile, sourcePath),
      });
    }
    for (const sourcePath of definition.documentStart ?? []) {
      entries.push({
        profile,
        phase: WEBVIEW_INJECT_DOCUMENT_START,
        sourcePath,
        source: await bundleScript(
          root, profile, "documentStart", sourcePath, optimize,
        ),
      });
    }
    for (const sourcePath of definition.documentEnd ?? []) {
      entries.push({
        profile,
        phase: WEBVIEW_INJECT_DOCUMENT_END,
        sourcePath,
        source: await bundleScript(
          root, profile, "documentEnd", sourcePath, optimize,
        ),
      });
    }
  }
  return entries;
}
