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

// Node-stdlib → bare-* shim aliases used when bundling workers. Required
// because some npm packages (e.g. `events-universal/default.js`) literally
// `require('events')`. Without these aliases, Vite externalizes the Node
// stdlib name for the browser worker target and emits the runtime error
// "Module 'events' has been externalized for browser compatibility."
//
// We map the common stdlib names to their bare-* counterparts so the same
// source resolves at bundle time. The `resolve.conditions: ["bare"]` we
// pass below covers the cleaner case where a package ships conditional
// exports (e.g. `events-universal` has a `bare` condition); the aliases
// catch the rest.
//
// Only added when bundling workers — the WebView main bundle is browser-
// targeted and shouldn't pull in bare-*.
const BARE_STDLIB_ALIASES: Record<string, string> = {
  events:       "bare-events",
  stream:       "bare-stream",
  "stream/web": "bare-stream/web",
  url:          "bare-url",
  buffer:       "bare-buffer",
  path:         "bare-path",
  os:           "bare-os",
  http:         "bare-http1",
  https:        "bare-https",
  zlib:         "bare-zlib",
  fs:           "bare-fs",
  "fs/promises":"bare-fs/promises",
  net:          "bare-net",
  tls:          "bare-tls",
  dns:          "bare-dns",
  crypto:       "bare-crypto",
  tty:          "bare-tty",
  process:      "bare-process",
};

// Vite plugin that rewrites `module.exports = require.addon()` (the
// canonical bare-* native binding loader, e.g. `bare-buffer/binding.js`)
// into a direct `Bare.addon('<id>')` lookup against bare's runtime addon
// registry.
//
// Why: when Vite bundles a worker that transitively pulls in
// `bare-tcp/binding.js`, the literal `require.addon()` call survives in
// the output bundle. At runtime our worker evaluates that bundle via
// `js_run_script` (script context — not a real CJS module), so neither
// `require` nor `require.addon` exists in scope. The bundled code blows
// up with "not a function" at the FIRST native binding init.
//
// The fix: at bundle time, replace the binding.js source with a call to
// `globalThis.Bare.addon('<bare_X>')`, which DOES exist (registered by
// bare's runtime). The `<bare_X>` id is the package name with `-`
// flipped to `_` — matches the `BARE_MODULE(bare_tcp, ...)` convention
// every Holepunch-shipped binding.c follows.
//
// This only takes effect for files matching `<…>/node_modules/bare-X/binding.js`.
// User code that does `require.addon('something')` deliberately is
// untouched.
//
// Caveat: the addon must actually be registered in libbare_modules.a. If
// not, `Bare.addon('bare_tcp')` throws "No addon registered for 'bare_tcp'"
// at runtime — which is a much clearer error than "not a function". The
// CLI side of T1.6 (build user-installed bare-* bindings into the
// archive) is a separate task tracked in project_bare_native_binding_link.md.
function bareBindingTransform(): Plugin {
  // Match e.g. "/abs/path/node_modules/bare-tcp/binding.js"
  // Reject "bare-bundle", "bare-pack" (and other non-`-binding.js` files);
  // only the file literally named binding.js inside a bare-* directory.
  const RE = /[/\\]node_modules[/\\](bare-[a-z0-9-]+)[/\\]binding\.js$/;
  return {
    name: "zapp-bare-binding-transform",
    enforce: "pre",
    async transform(code, id) {
      const m = id.match(RE);
      if (!m) return null;
      const pkg = m[1];  // "bare-tcp"

      // Read the package.json next to binding.js to capture the
      // resolved version. bare's runtime registers static addons
      // under `"${name}@${version}"` (set as BARE_MODULE_NAME at
      // compile time by cmake-bare's `link_bare_module`). The
      // `bare_addon_load_static` lookup is `strcmp`-based, so we
      // must pass the EXACT same string — including version.
      // Just `bare-dns` won't match `bare-dns@2.1.4`.
      const pkgJson = path.join(path.dirname(id), "package.json");
      let version = "0.0.0";
      try {
        const raw = await readFile(pkgJson, "utf-8");
        const parsed = JSON.parse(raw);
        if (typeof parsed.version === "string") version = parsed.version;
      } catch {
        // package.json missing or malformed — fall through with a
        // placeholder version. The runtime will throw a clear
        // "No addon registered for 'bare-X@0.0.0'" which tells the
        // user something's off with their install.
      }

      const specifier = `${pkg}@${version}`;

      // `Bare.Addon` is the class exposed on `globalThis.Bare` by
      // vendor/bare/src/bare.js (`exports.Addon = require('./addon')`).
      // `Addon.load(new URL('builtin:<spec>'))` reaches into
      // `bare.loadStaticAddon(url.pathname)`, which strcmp's against
      // the addon's stored specifier and returns the registered
      // native exports.
      //
      // NOT `globalThis.Bare.addon(...)` (lowercase) — that lives only
      // on the internal `bare` host object (a function-local in
      // bare.js), never reaches `globalThis.Bare`. Confirmed via a
      // Bare-surface dump.
      return {
        code:
          `// rewritten by @zappdev/vite zapp-bare-binding-transform\n` +
          `module.exports = globalThis.Bare.Addon.load(` +
          `new URL('builtin:${specifier}')` +
          `).exports;\n`,
        map: null,
      };
    },
  };
}

// Lower worker-bundle output to ES5 syntax — drops `class`, `let`,
// arrow functions, default params, template literals, etc. down to
// equivalents Hermes' parser handles without choking.
//
// Why a post-bundle pass instead of `build.target = "es5"`: Vite 8's
// Rolldown rejects `es5` as a target string (only es2017+ accepted),
// so we let Rollup emit es2017 then run a second `esbuild.transform`
// pass on each chunk. Esbuild's standalone API DOES accept `es5`.
//
// Cost on non-Hermes engines: ~10–15 KB of helper scaffolding per
// bundle (Object.assign polyfills, class prototypes, etc.) — small
// enough to apply uniformly. The alternative (per-engine targets)
// would mean two bundle outputs per worker, double the dev-build
// time, and a surprise when a user flips a worker from `bare-jsc`
// to `bare-hermes` and it stops working.
function hermesCompatLower(): Plugin {
  return {
    name: "zapp-hermes-compat-lower",
    enforce: "post",
    async renderChunk(code, chunk) {
      if (!chunk.fileName.endsWith(".mjs") && !chunk.fileName.endsWith(".js")) {
        return null;
      }
      const esbuild = await import("esbuild");
      // Two-pass lowering:
      //
      // Pass 1 (esbuild → es2017): lowers the modern syntax that
      // Hermes can't handle: `for await ... of` (ES2018), optional
      // chaining `?.` (ES2020), nullish coalescing `??` (ES2020),
      // logical assignment (ES2021), class fields & private methods
      // (ES2022). Async/await stays because Hermes 0.12+ supports
      // it natively.
      //
      // Pass 2 (babel → @babel/plugin-transform-classes): lowers
      // `class` syntax to ES5 prototype chains. We can't do this in
      // esbuild — esbuild explicitly errors when asked to lower
      // classes (it assumes input is ≤ ES2015 for that path), so
      // Babel is required for this specific lowering.
      //
      // Why we need class-lowering at all: Hermes' AST transformer
      // crashes (segfault, both hermesc and runtime) on certain
      // class shapes in bare-events:
      //   class e extends Error {
      //     constructor(t,n,r=e,i){...}
      //     static OPERATION_ABORTED(...) {...}
      //   }
      // Lowering classes to ES5 sidesteps that crash entirely.
      // Reproducible via libhermes' run-zapp-worker test.
      const esbuildResult = await esbuild.transform(code, {
        target: "es2017",
        minify: false,
        format: "esm",
        sourcemap: false,
      });

      const babel = await import("@babel/core");
      const babelResult = await babel.transformAsync(esbuildResult.code, {
        configFile: false,
        babelrc: false,
        plugins: [
          // `@babel/plugin-transform-classes` only; we don't pull in
          // `preset-env` because esbuild already handled everything
          // else and Babel's other plugins would re-do work.
          [(await import("@babel/plugin-transform-classes")).default, { loose: true }],
        ],
        compact: true,
        sourceMaps: false,
      });
      return { code: babelResult?.code ?? esbuildResult.code, map: null };
    },
  };
}

/**
 * Returns a Vite plugin that prepends
 * `import "@zappdev/runtime/worker-globals/<sub>"` lines to a specific
 * worker entry file. Resolves the globals into the bundle so each
 * capability's runtime shim runs before the user's worker code.
 *
 * Operates only on the exact entry path (we don't want every
 * transitively-imported module to also get the prepends).
 */
// Per-capability binding snippets. Each is a small JS snippet that
// assumes `_zappBindGlobal` (defined in the prelude common-prefix) is
// in scope and a default-imported binding for the capability's npm
// package is available. We inline the binding code rather than
// `import`ing a shim file under `@zappdev/runtime/worker-globals/<sub>`
// because that shim file lives outside the user's project root —
// Vite/Rolldown then treats its `node_modules` imports as external and
// leaves them as literal `import` statements in the worker bundle,
// which is a SyntaxError in `js_run_script` script context.
//
// Adding a new capability: pair `WORKER_MODULE_GLOBALS` (which subpath
// the user sees if they import manually) with the SNIPPET here (how
// the capability is hooked up under workerModules). The two should
// produce equivalent globals.
const WORKER_MODULE_BINDINGS: Record<string, { pkg: string; ident: string; body: string } | null> = {
  fetch: {
    pkg: "bare-fetch",
    ident: "__zappBareFetch",
    body: `
      _zappBindGlobal("fetch",    __zappBareFetch);
      _zappBindGlobal("Request",  __zappBareFetch.Request);
      _zappBindGlobal("Response", __zappBareFetch.Response);
      _zappBindGlobal("Headers",  __zappBareFetch.Headers);
      if (__zappBareFetch.FormData) _zappBindGlobal("FormData", __zappBareFetch.FormData);
      if (__zappBareFetch.Blob)     _zappBindGlobal("Blob",     __zappBareFetch.Blob);
    `,
  },
  websocket: null,  // TODO: bare-ws ABI not finalized
  fs:        null,  // fs is namespace-only (no globals to install)
  streams:   null,  // TODO: bare-stream/web global install
  crypto:    null,  // TODO: bare-crypto global install
  url:       null,  // TODO: bare-url global install
  encoding:  null,  // TODO: bare-encoding global install
};

function workerModulesPrelude(
  entryAbsPath: string,
  workerModules: readonly string[],
): Plugin | null {
  const importLines: string[] = [];
  const bindBodies: string[] = [];
  for (const cap of workerModules) {
    const binding = WORKER_MODULE_BINDINGS[cap];
    if (!binding) continue;
    importLines.push(`import ${binding.ident} from ${JSON.stringify(binding.pkg)};`);
    bindBodies.push(binding.body);
  }
  if (importLines.length === 0) return null;

  // Inline bindGlobal helper — placeholder marker matches the value
  // stamped onto `__zappPlaceholder` in `bootstrap/bare-worker.ts`.
  const helper = `
    function _zappBindGlobal(n, v) {
      if (v == null) return;
      var cur = globalThis[n];
      var isPlaceholder = typeof cur === "function" && cur.__zappPlaceholder === true;
      if (cur !== undefined && !isPlaceholder) return;
      try {
        Object.defineProperty(globalThis, n, {
          value: v, writable: true, configurable: true, enumerable: false,
        });
      } catch (_) {
        try { globalThis[n] = v; } catch (_) {}
      }
    }
  `;

  const prelude = importLines.join("\n") + "\n" + helper + "\n" + bindBodies.join("\n") + "\n";

  return {
    name: "zapp-worker-modules-prelude",
    enforce: "pre",
    transform(code, id) {
      if (id !== entryAbsPath) return null;
      return { code: prelude + code, map: null };
    },
  };
}

/** Bundle a single worker entry using Vite's build API (Rolldown in Vite 8). */
async function bundleWorker(
  entry: WorkerEntry,
  outDir: string,
  aliases: Record<string, string>,
  root: string,
  mode: string,
  workerModules: readonly string[] = [],
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

    // Merge user aliases ON TOP of the bare stdlib aliases (so user can
    // still override). Only present for worker bundling.
    const workerAliases: Record<string, string> = { ...BARE_STDLIB_ALIASES, ...aliases };

    const prelude = workerModulesPrelude(entry.sourcePath, workerModules);
    const plugins: Plugin[] = [bareBindingTransform(), hermesCompatLower()];
    if (prelude) plugins.push(prelude);

    await vite.build({
      configFile: false,
      logLevel: "silent",
      mode,
      define,
      plugins,
      // Anchor the inner build at the user's project root so Vite's
      // module resolution sees their `node_modules/` (where bare-fetch,
      // bare-stream, etc. live). Without an explicit `root`, Vite uses
      // `process.cwd()` — which is the same path during `bun run dev`
      // but is fragile to differ between dev/package contexts.
      root,
      build: {
        outDir,
        emptyOutDir: false,
        minify: true,
        // Rolldown emits ES2017 — the actual ES5 downlevel for
        // Hermes-safety happens in the `hermesCompatLower` plugin
        // above, which runs `esbuild.transform` on each chunk as a
        // post-bundle pass. (Rolldown rejects `target: "es5"`.)
        target: "es2017",
        // Worker target: Node-style globals are NOT available; the bare
        // runtime supplies its own. "browser"-shaped bundling produces
        // the smallest, most predictable output for the engines we
        // target (jsc / v8 / quickjs / mqjs all running inside bare).
        ssr: false,
        rollupOptions: {
          input: entry.sourcePath,
          // Inline EVERYTHING. The worker bundle is loaded via
          // `js_run_script` in *script* context (not module context),
          // so any external `import` statement Vite leaves on the
          // bundle output is a runtime SyntaxError. We treat
          // node_modules deps as bundle-time inputs, NOT runtime
          // imports — the user's `bare-fetch` etc. get inlined.
          //
          // The one exception is the `bare-*/binding.js` native
          // loaders, which the `zapp-bare-binding-transform` plugin
          // rewrites to `Bare.Addon.load(...)` so they don't need a
          // require/addon resolver at runtime.
          external: [],
          output: {
            format: "es",
            entryFileNames: entry.outputName,
            dir: outDir,
          },
        },
      },
      resolve: {
        alias: workerAliases,
        // `bare` makes packages that ship a `bare` export condition
        // (e.g. events-universal) resolve to their bare-specific entry.
        // Without this, Vite picks the `default` condition which
        // typically points at Node stdlib code and triggers the
        // "externalized for browser compatibility" error.
        conditions: ["bare", "import", "module", "default"],
      },
    });
    return true;
  } catch (e) {
    console.error(`[zapp] worker bundle failed: ${entry.specifier}`, e);
    return false;
  }
}

interface ZappWorkersOptions {
  /**
   * Headless workers to bundle, keyed by ID. Each value is either a
   * source path (string) or `{ script, restart? }` for supervised
   * workers (the restart policy is ignored at bundle time but the
   * script field is read).
   *
   * Output URL is `/_workers/_headless_<id>.mjs` — the native runtime
   * loads these at app startup via generated Zen-C code.
   */
  headless?: Record<string, string | { script: string; restart?: unknown }>;
  /**
   * Worker capabilities (see ZappConfig.workerModules). For each entry
   * we prepend `import "@zappdev/runtime/worker-globals/<subpath>"` to
   * every bundled worker entry, so the matching globals (fetch,
   * WebSocket, etc.) are installed without per-worker boilerplate.
   *
   * Pass through from `zapp.config.ts`'s `workerModules` field.
   */
  workerModules?: string[];
}

// Capability → worker-globals subpath. Must match
// cli/src/config.ts's WORKER_MODULE_CAPABILITIES.globals values.
// Vite plugin is published as a separate package so we duplicate this
// tiny mapping here rather than importing from cli/ (avoids a hard
// dep edge). When updating capabilities, update both places.
const WORKER_MODULE_GLOBALS: Record<string, string | null> = {
  fetch:     "/fetch",
  websocket: "/websocket",
  fs:        null,
  streams:   "/streams",
  crypto:    "/crypto",
  url:       "/url",
  encoding:  "/encoding",
};

function resolveHeadlessEntries(root: string, headless?: ZappWorkersOptions["headless"]): WorkerEntry[] {
  if (!headless) return [];
  const entries: WorkerEntry[] = [];
  for (const [id, value] of Object.entries(headless)) {
    const srcPath = typeof value === "string" ? value : value.script;
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

      // Extract alias paths for worker bundling. Vite normalizes
      // `resolve.alias` from `Record<string, string>` (user input) to
      // `Array<{find: string|RegExp, replacement: string}>` by the
      // time `configResolved` fires. We accept both forms — the
      // record path is dead code today but keeps the plugin tolerant
      // to future Vite versions that might re-shape this.
      const resolvedAlias = config.resolve?.alias;
      if (Array.isArray(resolvedAlias)) {
        aliases = {};
        for (const entry of resolvedAlias) {
          if (typeof entry.find === "string" && typeof entry.replacement === "string") {
            aliases[entry.find] = entry.replacement;
          }
        }
      } else if (resolvedAlias && typeof resolvedAlias === "object") {
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
        const ok = await bundleWorker(entry, devOutDir, aliases, root, mode, options?.workerModules ?? []);
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
        const ok = await bundleWorker(entry, outDir, aliases, root, mode, options?.workerModules ?? []);
        if (ok) {
          console.log(`[zapp] bundled worker: ${entry.outputName}`);
        }
      }
    },
  };
}

export default zappWorkers;
