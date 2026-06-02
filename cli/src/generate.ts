// Service binding generator — scans .zc files under zapp/ for service
// registrations and emits TypeScript bindings in src/zapp/.

import path from "node:path";
import { mkdir, readdir, unlink } from "node:fs/promises";
import { existsSync } from "node:fs";
import { resolveServiceTypes } from "./service-types";

interface ServiceBinding {
  name: string;
  handlerName: string;
  source: string;      // path the binding was scanned from (for dedupe warnings)
}

// Walk zapp/** collecting all .zc files. A service registration can live in
// app.zc or in any imported service file (e.g. zapp/services/keychain.zc) —
// the scanner treats them uniformly.
async function collectZcFiles(root: string): Promise<string[]> {
  const zappDir = path.join(root, "zapp");
  if (!existsSync(zappDir)) return [];

  const results: string[] = [];
  async function walk(dir: string): Promise<void> {
    let entries;
    try { entries = await readdir(dir, { withFileTypes: true }); }
    catch { return; }
    for (const entry of entries) {
      if (entry.name.startsWith(".")) continue;
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        await walk(full);
      } else if (entry.isFile() && entry.name.endsWith(".zc")) {
        results.push(full);
      }
    }
  }
  await walk(zappDir);
  return results;
}

export async function scanServices(root: string): Promise<ServiceBinding[]> {
  const files = await collectZcFiles(root);
  const bindings: ServiceBinding[] = [];
  const seen = new Map<string, string>();  // name → first file that registered it

  // Match: service.add("name", handler) or app.service.add("name", handler)
  const pattern = /\.service\.add\s*\(\s*"([^"]+)"\s*,\s*(\w+)/g;

  for (const file of files) {
    const content = await Bun.file(file).text();
    pattern.lastIndex = 0;
    let match;
    while ((match = pattern.exec(content)) !== null) {
      const [, name, handlerName] = match;
      const prior = seen.get(name);
      if (prior) {
        console.warn(
          `[zapp] service "${name}" is registered in multiple files ` +
          `(${path.relative(root, prior)} and ${path.relative(root, file)}); ` +
          `keeping the first one.`
        );
        continue;
      }
      seen.set(name, file);
      bindings.push({ name, handlerName, source: file });
    }
  }

  return bindings;
}

// Convert a service name into a valid JS identifier. Service names can use
// separators like `:`, `.`, `-` (e.g. `keychain:get`, `file.read`, `db-query`)
// — documented convention for grouping related handlers. JS identifiers can't
// contain those, so we camelCase across separators: `keychain:get` → `keychainGet`.
function toIdent(name: string): string {
  return name
    .replace(/[:\-.]+([a-zA-Z0-9])/g, (_, c) => c.toUpperCase())
    .replace(/[^a-zA-Z0-9_$]/g, "_");
}

function toFileName(name: string): string {
  const ident = toIdent(name);
  return ident.charAt(0).toUpperCase() + ident.slice(1);
}

// src/zapp/ is framework-owned generated output — clean anything not in the
// current binding set before writing new files so removing a service.add call
// deletes its binding on the next generate.
async function cleanStale(outDir: string, keep: Set<string>): Promise<void> {
  let entries;
  try { entries = await readdir(outDir, { withFileTypes: true }); }
  catch { return; }
  for (const entry of entries) {
    if (!entry.isFile()) continue;
    if (!/\.(ts|js)$/.test(entry.name)) continue;
    if (keep.has(entry.name)) continue;
    await unlink(path.join(outDir, entry.name));
  }
}

export async function generateBindings(root: string, typescript: boolean = true): Promise<number> {
  const bindings = await scanServices(root);
  const outDir = path.join(root, "src", "zapp");

  const ext = typescript ? ".ts" : ".js";
  const exports: string[] = [];
  const keep = new Set<string>();

  if (bindings.length > 0) {
    await mkdir(outDir, { recursive: true });

    // Cache .zc source by path — several services can share one file.
    const sourceCache = new Map<string, string>();
    async function readSource(file: string): Promise<string> {
      let s = sourceCache.get(file);
      if (s === undefined) {
        s = await Bun.file(file).text();
        sourceCache.set(file, s);
      }
      return s;
    }

    for (const binding of bindings) {
      const fnName = toIdent(binding.name);
      const fileName = toFileName(binding.name);

      let content: string;
      if (typescript) {
        const src = await readSource(binding.source);
        const { argsDecl, resultDecl, argsName, resultName } = resolveServiceTypes(
          fileName,
          src,
          binding.handlerName
        );
        content = `import { Services } from "@zappdev/runtime";

${argsDecl}
${resultDecl}

export async function ${fnName}(args?: ${argsName}): Promise<${resultName}> {
    return Services.invoke<${resultName}>("${binding.name}", args ?? {});
}
`;
      } else {
        content = `import { Services } from "@zappdev/runtime";

export async function ${fnName}(args) {
    return Services.invoke("${binding.name}", args ?? {});
}
`;
      }

      await Bun.write(path.join(outDir, `${fileName}${ext}`), content);
      if (typescript) {
        const argsName = `${fileName}Args`;
        const resultName = `${fileName}Result`;
        exports.push(`export { ${fnName} } from "./${fileName}";`);
        exports.push(`export type { ${argsName}, ${resultName} } from "./${fileName}";`);
      } else {
        exports.push(`export { ${fnName} } from "./${fileName}";`);
      }
      keep.add(`${fileName}${ext}`);
    }

    await Bun.write(path.join(outDir, `index${ext}`), exports.join("\n") + "\n");
    keep.add(`index${ext}`);
  }

  await cleanStale(outDir, keep);

  return bindings.length;
}
