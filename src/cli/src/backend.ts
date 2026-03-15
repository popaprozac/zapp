import path from "node:path";
import process from "node:process";
import { runCmd } from "./common";

const BACKEND_CONVENTIONS = ["backend.ts", "backend.js"];

async function findBackendScript(root: string): Promise<string | null> {
  for (const name of BACKEND_CONVENTIONS) {
    const candidate = path.join(root, name);
    if (await Bun.file(candidate).exists()) {
      return candidate;
    }
  }
  return null;
}

function resolveZappPackage(pkg: string, root: string): string | null {
  try {
    return require.resolve(pkg, { paths: [root] });
  } catch {
    // not found in node_modules
  }

  const monorepoFallbacks: Record<string, string> = {
    "@zapp/runtime": "packages/runtime/index.ts",
    "@zapp/backend": "packages/backend/index.ts",
  };
  const relative = monorepoFallbacks[pkg];
  if (!relative) return null;

  const candidate = path.resolve(root, relative);
  try {
    if (require("node:fs").existsSync(candidate)) return candidate;
  } catch {}

  return null;
}

export async function resolveAndBundleBackend({
  root,
  frontendDir,
  backendScript,
}: {
  root: string;
  frontendDir: string;
  backendScript?: string;
}): Promise<string | null> {
  let entryPath: string | null = null;

  if (backendScript) {
    entryPath = path.resolve(root, backendScript);
    if (!(await Bun.file(entryPath).exists())) {
      process.stderr.write(`[zapp] backend script not found: ${entryPath}\n`);
      return null;
    }
  } else {
    entryPath = await findBackendScript(root);
  }

  if (!entryPath) return null;

  process.stdout.write(`[zapp] bundling backend script: ${path.relative(root, entryPath)}\n`);

  const buildDir = path.join(root, ".zapp");
  if (!(await Bun.file(buildDir).exists())) {
    await runCmd("mkdir", ["-p", buildDir], { cwd: root });
  }

  const outFile = path.join(buildDir, "backend.bundle.js");

  const runtimePath = resolveZappPackage("@zapp/runtime", root);
  const backendPath = resolveZappPackage("@zapp/backend", root);

  if (!runtimePath || !backendPath) {
    process.stderr.write(
      `[zapp] could not resolve @zapp/runtime or @zapp/backend from ${root}\n` +
      `  Install them: bun add @zapp/runtime @zapp/backend\n`
    );
    return null;
  }

  const hasBunBuild =
    typeof (globalThis as any).Bun !== "undefined" &&
    (globalThis as any).Bun != null &&
    typeof (globalThis as any).Bun.build === "function";

  if (hasBunBuild) {
    const result = await (globalThis as any).Bun.build({
      entrypoints: [entryPath],
      outdir: buildDir,
      naming: "backend.bundle.js",
      target: "browser",
      format: "esm",
      sourcemap: "none",
      minify: false,
      plugins: [
        {
          name: "zapp-backend-alias",
          setup(build: any) {
            build.onResolve({ filter: /^@zapp\/backend$/ }, () => ({ path: backendPath }));
            build.onResolve({ filter: /^@zapp\/backend\/(.*)/ }, (args: any) => ({
              path: path.join(path.dirname(backendPath), args.path.slice("@zapp/backend/".length)),
            }));
            build.onResolve({ filter: /^@zapp\/runtime$/ }, () => ({ path: runtimePath }));
            build.onResolve({ filter: /^@zapp\/runtime\/(.*)/ }, (args: any) => ({
              path: path.join(path.dirname(runtimePath), args.path.slice("@zapp/runtime/".length)),
            }));
          },
        },
      ],
    });

    if (!result.success) {
      const lines = (result.logs ?? [])
        .map((log: any) => log?.message)
        .filter(Boolean)
        .join("\n");
      process.stderr.write(`[zapp] backend bundle failed:\n${lines}\n`);
      return null;
    }
  } else {
    const { build: esbuild } = await import("esbuild");
    await esbuild({
      entryPoints: [entryPath],
      bundle: true,
      format: "esm",
      platform: "browser",
      target: "es2022",
      sourcemap: false,
      minify: false,
      outfile: outFile,
      alias: {
        "@zapp/backend": backendPath,
        "@zapp/runtime": runtimePath,
      },
    });
  }

  return outFile;
}
