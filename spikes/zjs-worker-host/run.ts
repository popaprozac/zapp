import { mkdir, stat, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { generateZServiceDispatchers } from "../../cli/src/z-service-dispatcher";
import { generateZServiceRegistrationOverlay } from "../../cli/src/z-service-registration";
import {
  deriveZServiceManifest,
  parseZProgramMetadata,
} from "../../cli/src/z-program-metadata";

const spike = import.meta.dir;
const repository = resolve(spike, "../..");
const zRepository = process.env.ZAPP_Z_REPO ?? resolve(repository, "../z-lang");
const zjsRepository = process.env.ZAPP_ZJS_REPO ?? resolve(repository, "../zjs");
const build = resolve(spike, "build");
const generated = resolve(spike, ".zapp");
const adapterObject = resolve(build, "zapp_worker_zjs.o");
const adapterLibrary = resolve(build, "libzapp_worker_zjs.a");
const zEntry = resolve(repository, "native/z/smokes/zjs-worker-host/main.zs");
const zjsLibrary = resolve(
  process.env.ZAPP_ZJS_LIBRARY ?? resolve(zjsRepository, "build/libzjs.a"),
);

async function run(
  command: string[],
  cwd: string,
  capture = false,
): Promise<string> {
  const child = Bun.spawn(command, {
    cwd,
    stdout: capture ? "pipe" : "inherit",
    stderr: capture ? "pipe" : "inherit",
  });
  const stdout = capture ? await new Response(child.stdout).text() : "";
  const stderr = capture ? await new Response(child.stderr).text() : "";
  const status = await child.exited;
  if (status !== 0) {
    throw new Error(
      `${command[0]} exited with status ${status}`
      + (stderr.trim() ? `\n${stderr.trim()}` : ""),
    );
  }
  return stdout;
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
    entry: zEntry,
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

const compiler = [process.execPath, "run", "z"];
const metadataSource = await run(
  [...compiler, "metadata", generated],
  zRepository,
  true,
);
const serviceManifest = deriveZServiceManifest(
  parseZProgramMetadata(metadataSource),
  "WorkerServicesBuilder.register",
);
const dispatcher = await generateZServiceDispatchers(serviceManifest, {
  outputPath: resolve(generated, "generated/service-dispatchers.zs"),
  serviceContractModule: resolve(repository, "native/z/framework/service-contract.zs"),
  servicesModule: resolve(repository, "native/z/framework/services.zs"),
  asyncServiceContractModule: resolve(repository, "native/z/framework/async-service-contract.zs"),
  serviceLifecycleContractModule: resolve(repository, "native/z/api/zapp/service.zs"),
});
const registrationOverlay = await generateZServiceRegistrationOverlay(
  serviceManifest,
  dispatcher,
  resolve(generated, "generated/service-registration.zbuild.json"),
  {
    marker: "WorkerServicesBuilder.register",
    synchronous: "WorkerServicesBuilder.registerGenerated",
    asynchronous: "WorkerServicesBuilder.registerGeneratedAsync",
    synchronousWithLifecycle:
      "WorkerServicesBuilder.registerGeneratedWithLifecycle",
    asynchronousWithLifecycle:
      "WorkerServicesBuilder.registerGeneratedAsyncWithLifecycle",
    generatedModulePackage: null,
  },
);

await run(
  [
    ...compiler,
    "run",
    generated,
    "--generated",
    registrationOverlay,
    "--release",
  ],
  zRepository,
);
