/**
 * Zapp Vite Plugin — bundles workers and backend scripts.
 *
 * Discovers `new Worker("./path")` and `new SharedWorker("./path")` patterns,
 * bundles each as a separate entry, outputs to dist/_workers/.
 * Also handles the backend worker convention (src/backend.ts).
 *
 * @example
 * ```ts
 * import { zappWorkers } from "@zappdev/vite";
 * export default defineConfig({ plugins: [zappWorkers()] });
 * ```
 */

import type { Plugin, ViteDevServer } from "vite";
import path from "node:path";
import { existsSync } from "node:fs";
import { mkdir, readdir, stat, readFile } from "node:fs/promises";

const WORKER_PATTERN =
  /new\s+(?:SharedWorker|Worker)\s*\(\s*(?:new\s+URL\(\s*["'`](.+?)["'`]\s*,\s*import\.meta\.url\s*\)|["'`](.+?)["'`])/g;

interface WorkerEntry {
  /** Original specifier from source: "./worker.ts" */
  specifier: string;
  /** Absolute path to source file */
  sourcePath: string;
  /** Output name: "worker.mjs" */
  outputName: string;
  /** Output URL path: "/_workers/worker.mjs" */
  outputUrl: string;
}

/** Recursively scan for source files. */
async function scanDir(dir: string): Promise<string[]> {
  const results: string[] = [];
  try {
    const entries = await readdir(dir, { withFileTypes: true });
    for (const entry of entries) {
      if (entry.name.startsWith(".") || entry.name === "node_modules" || entry.name === "zapp") continue;
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        results.push(...await scanDir(full));
      } else if (/\.(ts|tsx|js|jsx|mjs)$/.test(entry.name)) {
        results.push(full);
      }
    }
  } catch {}
  return results;
}

/** Discover worker entries by scanning source files for new Worker() patterns. */
async function discoverWorkers(srcDir: string): Promise<WorkerEntry[]> {
  const files = await scanDir(srcDir);
  const found = new Map<string, WorkerEntry>();

  for (const file of files) {
    const content = await readFile(file, "utf-8");
    let match;
    WORKER_PATTERN.lastIndex = 0;
    while ((match = WORKER_PATTERN.exec(content)) !== null) {
      const spec = match[1] || match[2];
      if (!spec || found.has(spec)) continue;
      const sourcePath = path.resolve(path.dirname(file), spec);
      const baseName = path.basename(spec).replace(/\.[^.]+$/, "");
      found.set(spec, {
        specifier: spec,
        sourcePath,
        outputName: `${baseName}.mjs`,
        outputUrl: `/_workers/${baseName}.mjs`,
      });
    }
  }

  return [...found.values()];
}

/** Bundle a single worker entry using Vite's build API (Rolldown in Vite 8). */
async function bundleWorker(entry: WorkerEntry, outDir: string, aliases: Record<string, string>): Promise<boolean> {
  try {
    const vite = await import("vite");
    await vite.build({
      configFile: false,
      logLevel: "silent",
      build: {
        outDir,
        emptyOutDir: false,
        minify: true,
        rollupOptions: {
          input: entry.sourcePath,
          output: {
            format: "es",
            entryFileNames: entry.outputName,
            dir: outDir,
          },
        },
      },
      resolve: { alias: aliases },
    });
    return true;
  } catch (e) {
    console.error(`[zapp] worker bundle failed: ${entry.specifier}`, e);
    return false;
  }
}

export function zappWorkers(): Plugin {
  let root = "";
  let srcDir = "";
  let workers: WorkerEntry[] = [];
  let backendEntry: WorkerEntry | null = null;
  let aliases: Record<string, string> = {};
  let isDev = false;
  let outDir = "";

  return {
    name: "zapp-workers",
    enforce: "pre",

    configResolved(config) {
      root = config.root;
      srcDir = path.join(root, "src");
      outDir = path.join(root, "dist", "_workers");
      isDev = config.command === "serve";

      // Extract alias paths for worker bundling
      const resolvedAlias = config.resolve?.alias;
      if (resolvedAlias && typeof resolvedAlias === "object" && !Array.isArray(resolvedAlias)) {
        aliases = resolvedAlias as Record<string, string>;
      }
    },

    async buildStart() {
      // Discover workers from source
      workers = await discoverWorkers(srcDir);

      // Check for backend worker (convention: src/backend.ts)
      const backendPath = path.join(srcDir, "backend.ts");
      if (existsSync(backendPath)) {
        backendEntry = {
          specifier: "./backend.ts",
          sourcePath: backendPath,
          outputName: "backend.mjs",
          outputUrl: "/_workers/backend.mjs",
        };
      }

      if (workers.length > 0) {
        console.log(`[zapp] discovered ${workers.length} worker(s)`);
      }
      if (backendEntry) {
        console.log("[zapp] backend worker: src/backend.ts");
      }
    },

    // Rewrite new Worker("./worker.ts") → new Worker("/_workers/worker.mjs")
    transform(code, id) {
      if (!id.endsWith(".ts") && !id.endsWith(".tsx") && !id.endsWith(".js") && !id.endsWith(".jsx")) return null;
      if (id.includes("node_modules")) return null;

      let modified = false;
      let result = code;

      for (const entry of workers) {
        // Replace the specifier in new Worker("./worker.ts") with the output URL
        const escaped = entry.specifier.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
        const regex = new RegExp(`(new\\s+(?:SharedWorker|Worker)\\s*\\(\\s*["'\`])${escaped}(["'\`])`, "g");
        const replaced = result.replace(regex, `$1${entry.outputUrl}$2`);
        if (replaced !== result) {
          result = replaced;
          modified = true;
        }
      }

      return modified ? { code: result, map: null } : null;
    },

    // Dev: serve workers from middleware
    configureServer(server: ViteDevServer) {
      const devOutDir = path.join(root, ".zapp", "workers");

      server.middlewares.use(async (req, res, next) => {
        if (!req.url?.startsWith("/_workers/")) return next();

        const fileName = req.url.slice("/_workers/".length);
        const filePath = path.join(devOutDir, fileName);

        // Bundle on-demand if not cached
        if (!existsSync(filePath)) {
          const entry = [...workers, backendEntry].find(w => w?.outputName === fileName);
          if (entry) {
            await mkdir(devOutDir, { recursive: true });
            await bundleWorker(entry, devOutDir, aliases);
          }
        }

        if (existsSync(filePath)) {
          const content = await readFile(filePath, "utf-8");
          res.setHeader("Content-Type", "application/javascript");
          res.end(content);
        } else {
          res.statusCode = 404;
          res.end("Worker not found");
        }
      });
    },

    // Prod: bundle all workers to dist/_workers/
    async generateBundle() {
      if (isDev) return;

      await mkdir(outDir, { recursive: true });

      const allEntries = [...workers];
      if (backendEntry) allEntries.push(backendEntry);

      for (const entry of allEntries) {
        const ok = await bundleWorker(entry, outDir, aliases);
        if (ok) {
          console.log(`[zapp] bundled worker: ${entry.outputName}`);
        }
      }
    },
  };
}

export default zappWorkers;
