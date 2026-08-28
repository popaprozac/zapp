import { expect, test } from "bun:test";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  buildWebviewInjections,
  renderWebviewInjectionsC,
  WEBVIEW_INJECT_DOCUMENT_END,
  WEBVIEW_INJECT_DOCUMENT_START,
  WEBVIEW_INJECT_STYLE,
} from "./webview-injections";

test("buildWebviewInjections preserves profile and phase ordering", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "zapp-inject-"));
  try {
    await mkdir(path.join(root, "src"));
    await writeFile(path.join(root, "src", "base.css"), ":root{--ready:yes}");
    await writeFile(
      path.join(root, "src", "preload.ts"),
      'globalThis.document.title = "preloaded";',
    );
    await writeFile(
      path.join(root, "src", "ready.ts"),
      'globalThis.document.title = "ready";',
    );

    const entries = await buildWebviewInjections(root, {
      base: {
        styles: ["src/base.css"],
        documentStart: ["src/preload.ts"],
        documentEnd: ["src/ready.ts"],
      },
    }, false);

    expect(entries.map(({ profile, phase, sourcePath }) => ({
      profile, phase, sourcePath,
    }))).toEqual([
      { profile: "base", phase: WEBVIEW_INJECT_STYLE, sourcePath: "src/base.css" },
      { profile: "base", phase: WEBVIEW_INJECT_DOCUMENT_START, sourcePath: "src/preload.ts" },
      { profile: "base", phase: WEBVIEW_INJECT_DOCUMENT_END, sourcePath: "src/ready.ts" },
    ]);
    expect(entries[0].source).toContain("--ready:yes");
    expect(entries[1].source).toContain("preloaded");
    expect(entries[2].source).toContain("ready");

    const c = renderWebviewInjectionsC(entries);
    expect(c).toContain('{"base", 0, zapp_webview_injection_0');
    expect(c).toContain('{"base", 1, zapp_webview_injection_1');
    expect(c).toContain('{"base", 2, zapp_webview_injection_2');
    expect(c).toContain("zapp_webview_injection_profile_exists");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("renderWebviewInjectionsC emits a warning-clean empty registry shape", () => {
  const c = renderWebviewInjectionsC([]);
  expect(c).toContain("return 0;");
  expect(c).not.toContain("zapp_webview_injections[1]");
});

test("buildWebviewInjections reports profile-qualified file errors", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "zapp-inject-error-"));
  try {
    await expect(buildWebviewInjections(root, {
      base: { styles: ["src/missing.css"] },
    }, false)).rejects.toThrow(/webview\.inject\.base style "src\/missing\.css"/);
    await expect(buildWebviewInjections(root, {
      base: { documentStart: ["src/preload.css"] },
    }, false)).rejects.toThrow(/must be a JavaScript or TypeScript file/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
