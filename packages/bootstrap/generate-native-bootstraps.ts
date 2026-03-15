import { mkdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";

type BootstrapEntry = {
  source: string;
  output: string;
  fnName: string;
};

const projectRoot = resolve(new URL(".", import.meta.url).pathname, "../..");

const entries: BootstrapEntry[] = [
  {
    source: resolve(projectRoot, "packages/bootstrap/src/worker.ts"),
    output: resolve(projectRoot, "src/platform/darwin/bootstrap.zc"),
    fnName: "zapp_darwin_worker_bootstrap_script",
  },
  {
    source: resolve(projectRoot, "packages/bootstrap/src/webview.ts"),
    output: resolve(projectRoot, "src/platform/darwin/webview_bootstrap.zc"),
    fnName: "zapp_darwin_webview_bootstrap_script",
  },
  {
    source: resolve(projectRoot, "packages/bootstrap/src/backend.ts"),
    output: resolve(projectRoot, "src/platform/darwin/backend_bootstrap.zc"),
    fnName: "zapp_darwin_backend_bootstrap_script",
  },
];

const toCStringLiteral = (input: string): string =>
  input
    .replace(/\\/g, "\\\\")
    .replace(/"/g, '\\"')
    .replace(/\?\?/g, "?\\?")
    .replace(/\n/g, "\\n");

const bundleScript = async (entryFile: string): Promise<string> => {
  const result = await Bun.build({
    entrypoints: [entryFile],
    target: "browser",
    format: "iife",
    minify: true,
    sourcemap: "none",
    splitting: false,
    throw: true,
  });

  const artifact =
    result.outputs.find((output) => output.kind === "entry-point") ??
    result.outputs.find((output) => output.loader === "js");

  if (!artifact) {
    throw new Error(`No output produced for ${entryFile}`);
  }

  return artifact.text();
};

const renderZc = (functionName: string, jsCode: string, sourcePath: string): string => {
  const cLiteral = toCStringLiteral(jsCode);
  return `// AUTO-GENERATED FILE. DO NOT EDIT.
// Source of truth: \`${sourcePath}\`
// Generated: \`${new Date().toISOString()}\`

raw {
    const char* ${functionName}(void) {
        return "${cLiteral}";
    }
}
`;
};

for (const entry of entries) {
  const js = await bundleScript(entry.source);
  const content = renderZc(
    entry.fnName,
    js,
    entry.source.replace(`${projectRoot}/`, "")
  );
  await mkdir(dirname(entry.output), { recursive: true });
  await Bun.write(entry.output, content);
  console.log(`Generated ${entry.output}`);
}
