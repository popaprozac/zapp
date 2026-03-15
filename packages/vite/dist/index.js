import fs from "node:fs/promises";
import path from "node:path";
const WORKER_PATTERN = /new\s+(?:SharedWorker|Worker)\s*\(\s*(?:new\s+URL\(\s*["'`](.+?)["'`]\s*,\s*import\.meta\.url\s*\)|["'`](.+?)["'`])/g;
const scanSourceFiles = async (rootDir, dir = rootDir, out = []) => {
    const entries = await fs.readdir(dir, { withFileTypes: true });
    for (const entry of entries) {
        if (entry.name.startsWith("."))
            continue;
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) {
            if (entry.name === "node_modules")
                continue;
            await scanSourceFiles(rootDir, full, out);
            continue;
        }
        if (!/\.(ts|tsx|js|jsx|mjs|cjs)$/.test(entry.name))
            continue;
        out.push(full);
    }
    return out;
};
const discoverWorkerEntries = async (srcRoot) => {
    const sourceFiles = await scanSourceFiles(srcRoot);
    const found = new Map();
    for (const file of sourceFiles) {
        const content = await fs.readFile(file, "utf8");
        let match;
        while ((match = WORKER_PATTERN.exec(content)) != null) {
            const spec = match[1] ?? match[2];
            if (!spec || !/\.(ts|tsx|js|jsx|mjs)$/.test(spec))
                continue;
            const entryPath = path.resolve(path.dirname(file), spec);
            found.set(entryPath, spec);
        }
    }
    return [...found.entries()].map(([entryPath, sourceSpec]) => ({ entryPath, sourceSpec }));
};
const normalizeOutName = (entryPath, used) => {
    const stem = path.basename(entryPath).replace(/\.[^.]+$/, "");
    let candidate = `${stem}.mjs`;
    let suffix = 1;
    while (used.has(candidate)) {
        candidate = `${stem}-${suffix}.mjs`;
        suffix += 1;
    }
    used.add(candidate);
    return candidate;
};
export const zapp = (options = {}) => {
    const workerOutDir = options.outDir ?? "public/zapp-workers";
    const sourceRoot = options.sourceRoot ?? "src";
    const minify = options.minify ?? false;
    let root = process.cwd();
    let devServer = false;
    let viteAliases = {};
    let timer = null;
    const hasBunBuild = typeof globalThis.Bun !== "undefined" &&
        globalThis.Bun != null &&
        typeof globalThis.Bun.build === "function";
    const bundleWorker = async (entryPath, outFile) => {
        if (hasBunBuild) {
            const result = await globalThis.Bun.build({
                entrypoints: [entryPath],
                outfile: outFile,
                target: "browser",
                format: "esm",
                sourcemap: devServer ? "inline" : "none",
                minify: devServer ? false : minify,
                plugins: [{
                        name: "zapp-alias",
                        setup(build) {
                            for (const [find, replacement] of Object.entries(viteAliases)) {
                                build.onResolve({ filter: new RegExp(`^${find}$`) }, () => ({ path: replacement }));
                                build.onResolve({ filter: new RegExp(`^${find}/(.*)`) }, (args) => ({
                                    path: path.join(replacement, args.path.slice(find.length + 1))
                                }));
                            }
                        }
                    }],
            });
            if (!result.success) {
                const lines = (result.logs ?? [])
                    .map((log) => log?.message)
                    .filter(Boolean)
                    .join("\n");
                throw new Error(lines || `bun build failed for ${entryPath}`);
            }
            return;
        }
        const { build: esbuild } = await import("esbuild");
        await esbuild({
            entryPoints: [entryPath],
            bundle: true,
            format: "esm",
            platform: "browser",
            target: "es2022",
            sourcemap: devServer ? "inline" : false,
            minify: devServer ? false : minify,
            outfile: outFile,
            alias: viteAliases,
        });
    };
    const buildWorkers = async () => {
        const srcRoot = path.resolve(root, sourceRoot);
        const outDir = path.resolve(root, workerOutDir);
        await fs.mkdir(outDir, { recursive: true });
        const entries = await discoverWorkerEntries(srcRoot);
        const usedNames = new Set();
        const manifest = {};
        for (const { entryPath, sourceSpec } of entries) {
            const outName = normalizeOutName(entryPath, usedNames);
            const outFile = path.join(outDir, outName);
            await bundleWorker(entryPath, outFile);
            manifest[sourceSpec] = `/zapp-workers/${outName}`;
            manifest[path.basename(sourceSpec)] = `/zapp-workers/${outName}`;
        }
        await fs.writeFile(path.join(outDir, "manifest.json"), JSON.stringify({ v: 1, generatedAt: new Date().toISOString(), workers: manifest }, null, 2));
        return manifest;
    };
    return {
        name: "zapp-workers",
        configResolved(config) {
            root = config.root;
            devServer = config.command === "serve";
            if (Array.isArray(config.resolve?.alias)) {
                for (const a of config.resolve.alias) {
                    if (typeof a.find === "string" && typeof a.replacement === "string") {
                        viteAliases[a.find] = a.replacement;
                    }
                }
            }
            else if (config.resolve?.alias) {
                Object.assign(viteAliases, config.resolve.alias);
            }
        },
        async buildStart() {
            await buildWorkers();
        },
        async transformIndexHtml(html) {
            const manifestPath = path.resolve(root, workerOutDir, "manifest.json");
            let workers = {};
            try {
                const raw = await fs.readFile(manifestPath, "utf8");
                workers = JSON.parse(raw).workers ?? {};
            }
            catch {
                workers = {};
            }
            const serialized = JSON.stringify(workers).replace(/</g, "\\u003c");
            const script = `<script>(function(){globalThis[Symbol.for('zapp.workerManifest')]=${serialized};})();</script>`;
            return html.includes("</head>") ? html.replace("</head>", `${script}</head>`) : `${script}${html}`;
        },
        configureServer(server) {
            devServer = true;
            const outDir = path.resolve(root, workerOutDir);
            server.middlewares.use((req, res, next) => {
                const url = req.url ?? "";
                if (!url.startsWith("/zapp-workers/"))
                    return next();
                const fileName = url.slice("/zapp-workers/".length).split("?")[0];
                if (!fileName)
                    return next();
                const filePath = path.join(outDir, fileName);
                fs.readFile(filePath, "utf8").then((content) => {
                    res.setHeader("Content-Type", "application/javascript; charset=utf-8");
                    res.setHeader("Cache-Control", "no-cache");
                    res.end(content);
                }).catch(() => next());
            });
            const rebuild = () => {
                if (timer)
                    clearTimeout(timer);
                timer = setTimeout(() => {
                    buildWorkers().catch((error) => {
                        server.config.logger.error(`[zapp-workers] ${error.message}`);
                    });
                }, 120);
            };
            server.watcher.on("add", rebuild);
            server.watcher.on("change", rebuild);
            server.watcher.on("unlink", rebuild);
        },
    };
};
export default zapp;
