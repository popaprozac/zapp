// Service binding generator — scans .zc files for service registrations
// and generates TypeScript bindings in src/zapp/

import path from "node:path";
import { mkdir } from "node:fs/promises";

interface ServiceBinding {
  name: string;
  handlerName: string;
}

export async function scanServices(root: string): Promise<ServiceBinding[]> {
  const appZc = path.join(root, "zapp", "app.zc");
  const file = Bun.file(appZc);
  if (!(await file.exists())) return [];

  const content = await file.text();
  const bindings: ServiceBinding[] = [];

  // Match: service.add("name", handler) or app.service.add("name", handler)
  const pattern = /\.service\.add\s*\(\s*"([^"]+)"\s*,\s*(\w+)/g;
  let match;
  while ((match = pattern.exec(content)) !== null) {
    bindings.push({ name: match[1], handlerName: match[2] });
  }

  return bindings;
}

function capitalize(s: string): string {
  return s.charAt(0).toUpperCase() + s.slice(1);
}

export async function generateBindings(root: string, typescript: boolean = true): Promise<number> {
  const bindings = await scanServices(root);
  if (bindings.length === 0) return 0;

  const outDir = path.join(root, "src", "zapp");
  await mkdir(outDir, { recursive: true });

  const ext = typescript ? ".ts" : ".js";
  const exports: string[] = [];

  for (const binding of bindings) {
    const name = capitalize(binding.name);
    const content = typescript
      ? `import { Services } from "@zappdev/runtime";

export async function ${binding.name}(args?: Record<string, unknown>): Promise<unknown> {
    return Services.invoke("${binding.name}", args ?? {});
}
`
      : `import { Services } from "@zappdev/runtime";

export async function ${binding.name}(args) {
    return Services.invoke("${binding.name}", args ?? {});
}
`;

    await Bun.write(path.join(outDir, `${name}${ext}`), content);
    exports.push(`export { ${binding.name} } from "./${name}";`);
  }

  // Write index
  await Bun.write(path.join(outDir, `index${ext}`), exports.join("\n") + "\n");

  return bindings.length;
}
