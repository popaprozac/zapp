import { mkdir, stat, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";

const spike = import.meta.dir;
const repository = resolve(spike, "../..");
const zRepository = process.env.ZAPP_Z_REPO ?? resolve(repository, "../z-lang");
const zjsRepository = process.env.ZAPP_ZJS_REPO ?? resolve(repository, "../zjs");
const build = resolve(spike, "build");
const generated = resolve(spike, ".zapp");
const adapterObject = resolve(build, "zapp_worker_zjs.o");
const adapterLibrary = resolve(build, "libzapp_worker_zjs.a");
const zjsLibrary = resolve(
  process.env.ZAPP_ZJS_LIBRARY ?? resolve(zjsRepository, "build/libzjs.a"),
);

async function run(command: string[], cwd: string): Promise<void> {
  const child = Bun.spawn(command, {
    cwd,
    stdout: "inherit",
    stderr: "inherit",
  });
  const status = await child.exited;
  if (status !== 0) {
    throw new Error(`${command[0]} exited with status ${status}`);
  }
}

async function exists(path: string): Promise<boolean> {
  try {
    await stat(path);
    return true;
  } catch {
    return false;
  }
}

await mkdir(build, { recursive: true });
await mkdir(generated, { recursive: true });

if (!(await exists(zjsLibrary))) {
  const make = ["make", "stdlib-embed", "lib-static", "ZJS_TIER=minimal"];
  if (process.env.ZAPP_ZC) make.push(`ZC=${process.env.ZAPP_ZC}`);
  if (process.env.ZAPP_ZC_ROOT) {
    make.push(`ZC_ROOT=${process.env.ZAPP_ZC_ROOT}`);
  }
  await run(make, zjsRepository);
}
if (!(await exists(zjsLibrary))) {
  throw new Error(
    `ZJS static library was not produced at ${zjsLibrary}. ` +
    "Build ZJS with `make stdlib-embed lib-static ZJS_TIER=minimal` " +
    "or set ZAPP_ZJS_LIBRARY.",
  );
}

await run([
  "clang",
  "-O2",
  "-I",
  resolve(zjsRepository, "include"),
  "-I",
  resolve(spike, "adapter"),
  "-c",
  resolve(spike, "adapter/zapp_worker_zjs.c"),
  "-o",
  adapterObject,
], repository);
await run(["ar", "rcs", adapterLibrary, adapterObject], repository);

await writeFile(resolve(generated, "z.json"), `${JSON.stringify({
  target: {
    kind: "executable",
    name: "zapp_zjs_worker_host",
    entry: "../main.zs",
    platform: "macos",
    minimumVersion: "14.0",
    includeDirectories: [
      resolve(spike, "adapter"),
      resolve(zjsRepository, "include"),
    ],
    link: {
      directories: [build, dirname(zjsLibrary)],
      libraries: ["zapp_worker_zjs", "zjs", "z"],
      frameworks: ["Foundation", "Security"],
    },
  },
}, null, 2)}\n`);

await run(
  ["bun", "run", "z", "run", generated, "--release"],
  zRepository,
);
