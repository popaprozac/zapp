// Worker script bundler — discovers and bundles worker scripts.
// Scans source files for `new Worker('./path.ts')` patterns,
// bundles each with Bun.build, outputs to .zapp/workers/.

import path from "node:path";
import { mkdir, readdir, readFile, stat } from "node:fs/promises";

const WORKER_PATTERN =
  /new\s+(?:SharedWorker|Worker)\s*\(\s*(?:new\s+URL\(\s*["'`](.+?)["'`]\s*,\s*import\.meta\.url\s*\)|["'`](.+?)["'`])/g;

async function scanSourceFiles(dir: string): Promise<string[]> {
  const results: string[] = [];
  const entries = await readdir(dir, { withFileTypes: true });
  for (const entry of entries) {
    if (entry.name.startsWith(".") || entry.name === "node_modules" || entry.name === "zapp") continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      results.push(...await scanSourceFiles(full));
    } else if (/\.(ts|tsx|js|jsx|mjs)$/.test(entry.name)) {
      results.push(full);
    }
  }
  return results;
}

interface WorkerEntry {
  entryPath: string;  // Absolute path to the worker source file
  specifier: string;  // Original specifier from new Worker('...')
}

async function discoverWorkers(srcDir: string): Promise<WorkerEntry[]> {
  const files = await scanSourceFiles(srcDir);
  const found = new Map<string, string>();
  for (const file of files) {
    const content = await readFile(file, "utf8");
    let match;
    WORKER_PATTERN.lastIndex = 0;
    while ((match = WORKER_PATTERN.exec(content)) !== null) {
      const spec = match[1] ?? match[2];
      if (!spec || !/\.(ts|tsx|js|jsx|mjs)$/.test(spec)) continue;
      const entryPath = path.resolve(path.dirname(file), spec);
      found.set(entryPath, spec);
    }
  }
  return [...found.entries()].map(([entryPath, specifier]) => ({ entryPath, specifier }));
}

export async function bundleWorkers(root: string, backendConfig?: string): Promise<number> {
  const srcDir = path.join(root, "src");
  const outDir = path.join(root, ".zapp", "workers");
  await mkdir(outDir, { recursive: true });

  const workers = await discoverWorkers(srcDir);

  for (const worker of workers) {
    // Check if source exists
    try {
      await stat(worker.entryPath);
    } catch {
      process.stderr.write(`[zapp] worker script not found: ${worker.entryPath}\n`);
      continue;
    }

    const outName = path.basename(worker.entryPath).replace(/\.[^.]+$/, ".mjs");
    const outPath = path.join(outDir, outName);

    const result = await Bun.build({
      entrypoints: [worker.entryPath],
      outdir: path.dirname(outPath),
      naming: path.basename(outPath),
      target: "browser",
      format: "esm",
      minify: false,
    });

    if (!result.success) {
      process.stderr.write(`[zapp] worker bundle failed: ${worker.specifier}\n`);
      for (const log of result.logs) {
        process.stderr.write(`  ${log}\n`);
      }
    }
  }

  // Backend worker — from config or fall back to src/backend.ts convention
  const backendPath = backendConfig
    ? path.resolve(root, backendConfig)
    : path.join(root, "src", "backend.ts");
  try {
    await stat(backendPath);
    const outPath = path.join(outDir, "backend.mjs");
    const result = await Bun.build({
      entrypoints: [backendPath],
      outdir: path.dirname(outPath),
      naming: "backend.mjs",
      target: "browser",
      format: "esm",
      minify: false,
    });
    if (result.success) {
      process.stdout.write(`[zapp] backend worker: ${path.relative(root, backendPath)}\n`);
    } else {
      process.stderr.write("[zapp] backend bundle failed\n");
    }
  } catch {
    // No backend file — that's fine, backend is optional
  }

  return workers.length;
}
