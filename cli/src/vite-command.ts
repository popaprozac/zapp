import { existsSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, resolve } from "node:path";

/** Use the application's installed toolchain, never bunx's temporary @latest.
 * Node resolution also supports a dependency installed at a workspace root. */
export function resolveViteCommand(root: string, args: readonly string[]): string[] {
  const project = resolve(root);
  let manifest: string;
  try {
    manifest = createRequire(resolve(project, "package.json")).resolve("vite/package.json");
  } catch {
    throw new Error(
      `[zapp] Cannot find the project's installed Vite from ${project}.\n`
      + "Declare vite in the project's devDependencies and run bun install. "
      + "Zapp will not download an unpinned Vite during dev or build.",
    );
  }
  const pkg = JSON.parse(readFileSync(manifest, "utf8")) as {
    bin?: string | { vite?: string };
  };
  const bin = typeof pkg.bin === "string" ? pkg.bin : pkg.bin?.vite;
  if (typeof bin !== "string" || bin.length === 0) {
    throw new Error(`[zapp] Installed Vite has no CLI entry in ${manifest}. Reinstall the project's dependencies with bun install.`);
  }
  const entry = resolve(dirname(manifest), bin);
  if (!existsSync(entry)) {
    throw new Error(`[zapp] Installed Vite CLI is missing at ${entry}. Reinstall the project's dependencies with bun install.`);
  }
  // Preserve Vite's Node runtime (as selected by its normal CLI shebang),
  // while passing the exact resolved entry and each argument without a shell.
  return ["node", entry, ...args];
}
