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
async function bundleWorker(
  entry: WorkerEntry,
  outDir: string,
  aliases: Record<string, string>,
  root: string,
  mode: string,
): Promise<boolean> {
  try {
    const vite = await import("vite");
    // We use configFile:false here to avoid recursion (this bundle is called
    // from inside a Vite plugin). That opts us out of Vite's usual env
    // handling, so load VITE_* vars manually and replicate the MODE/DEV/PROD
    // replacements the main build gets for free.
    const env = vite.loadEnv(mode, root, "");
    const define: Record<string, string> = {};
    for (const [k, v] of Object.entries(env)) {
      if (k.startsWith("VITE_")) define[`import.meta.env.${k}`] = JSON.stringify(v);
    }
    define["import.meta.env.MODE"] = JSON.stringify(mode);
    define["import.meta.env.DEV"] = JSON.stringify(mode !== "production");
    define["import.meta.env.PROD"] = JSON.stringify(mode === "production");

    await vite.build({
      configFile: false,
      logLevel: "silent",
      mode,
      define,
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

interface ZappWorkersOptions {
  /**
   * Headless workers to bundle, keyed by ID. Values are source paths relative
   * to project root. Output URL is `/_workers/_headless_<id>.mjs` — the native
   * runtime loads these at app startup via generated Zen-C code.
   */
  headless?: Record<string, string>;
}

function resolveHeadlessEntries(root: string, headless?: Record<string, string>): WorkerEntry[] {
  if (!headless) return [];
  const entries: WorkerEntry[] = [];
  for (const [id, srcPath] of Object.entries(headless)) {
    const abs = path.resolve(root, srcPath);
    if (!existsSync(abs)) {
      console.warn(`[zapp] headless worker "${id}" not found at ${srcPath}`);
      continue;
    }
    entries.push({
      specifier: srcPath,
      sourcePath: abs,
      outputName: `_headless_${id}.mjs`,
      outputUrl: `/_workers/_headless_${id}.mjs`,
    });
  }
  return entries;
}

export function zappWorkers(options?: ZappWorkersOptions): Plugin {
  let root = "";
  let srcDir = "";
  let workers: WorkerEntry[] = [];
  let headlessEntries: WorkerEntry[] = [];
  let aliases: Record<string, string> = {};
  let isDev = false;
  let mode = "production";
  let outDir = "";

  return {
    name: "zapp-workers",
    enforce: "pre",

    configResolved(config) {
      root = config.root;
      srcDir = path.join(root, "src");
      outDir = path.join(root, "dist", "_workers");
      isDev = config.command === "serve";
      mode = config.mode;

      // Extract alias paths for worker bundling
      const resolvedAlias = config.resolve?.alias;
      if (resolvedAlias && typeof resolvedAlias === "object" && !Array.isArray(resolvedAlias)) {
        aliases = resolvedAlias as Record<string, string>;
      }
    },

    async buildStart() {
      // Webview-spawned workers: discovered by scanning source.
      workers = await discoverWorkers(srcDir);

      // Headless workers: declared in zapp.config.ts.
      headlessEntries = resolveHeadlessEntries(root, options?.headless);

      if (workers.length > 0) {
        console.log(`[zapp] discovered ${workers.length} worker(s)`);
      }
      for (const entry of headlessEntries) {
        console.log(`[zapp] headless worker: ${path.relative(root, entry.sourcePath)}`);
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

    // Dev: bundle workers eagerly so they exist on disk before the native
    // binary launches. Headless workers are loaded directly by native code
    // via the generated .zapp/zapp_headless_workers.zc, so a lazy-on-request
    // middleware would never bundle them. Eager bundling also lets native
    // fall back to filesystem.
    //
    // configureServer runs before buildStart, so we re-discover workers here
    // (buildStart's results aren't yet available).
    async configureServer(server: ViteDevServer) {
      const devOutDir = path.join(root, ".zapp", "workers");
      await mkdir(devOutDir, { recursive: true });

      workers = await discoverWorkers(srcDir);
      headlessEntries = resolveHeadlessEntries(root, options?.headless);

      const allEntries = [...workers, ...headlessEntries];
      for (const entry of allEntries) {
        const ok = await bundleWorker(entry, devOutDir, aliases, root, mode);
        if (ok) console.log(`[zapp] dev-bundled worker: ${entry.outputName}`);
      }

      // Still expose middleware so WebView fetch of /_workers/<name>.mjs works
      // (e.g. native engines that pull via dev URL like jsc.m).
      server.middlewares.use(async (req, res, next) => {
        if (!req.url?.startsWith("/_workers/")) return next();

        const fileName = req.url.slice("/_workers/".length);
        const filePath = path.join(devOutDir, fileName);

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

      const allEntries = [...workers, ...headlessEntries];

      for (const entry of allEntries) {
        const ok = await bundleWorker(entry, outDir, aliases, root, mode);
        if (ok) {
          console.log(`[zapp] bundled worker: ${entry.outputName}`);
        }
      }
    },
  };
}

export default zappWorkers;
