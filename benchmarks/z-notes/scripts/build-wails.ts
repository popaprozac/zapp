import { existsSync } from "node:fs";
import { chmod, copyFile, mkdir, mkdtemp, rm } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { processIcon } from "../../../cli/src/icon";

const repository = resolve(import.meta.dir, "../../..");
const application = resolve(import.meta.dir, "../apps/wails");
const frontend = resolve(application, "frontend");
const executable = "z-notes-benchmark-wails";
const bundle = resolve(application, "release/Z Notes Benchmark Wails.app");
const macos = resolve(bundle, "Contents/MacOS");
const resources = resolve(bundle, "Contents/Resources");
const wails = Bun.which("wails3") ?? resolve(homedir(), "go/bin/wails3");

async function run(
  command: string[],
  cwd = application,
  env: Record<string, string | undefined> = process.env,
): Promise<string> {
  const child = Bun.spawn(command, {
    cwd,
    env,
    stdout: "pipe",
    stderr: "inherit",
  });
  const output = await new Response(child.stdout).text();
  const status = await child.exited;
  if (status !== 0) process.exit(status);
  return output.trim();
}

if (!existsSync(wails)) {
  throw new Error(
    "wails3 is required; install github.com/wailsapp/wails/v3/cmd/wails3@v3.0.0-beta.16",
  );
}
const versionProbe = Bun.spawn([wails, "version"], {
  cwd: repository,
  stdout: "pipe",
  stderr: "pipe",
});
const [versionStdout, versionStderr, versionStatus] = await Promise.all([
  new Response(versionProbe.stdout).text(),
  new Response(versionProbe.stderr).text(),
  versionProbe.exited,
]);
if (versionStatus !== 0) process.exit(versionStatus);
const wailsVersion = (versionStdout || versionStderr).trim();
if (wailsVersion !== "v3.0.0-beta.16") {
  throw new Error(
    `expected wails3 v3.0.0-beta.16, found ${wailsVersion}; install the pinned CLI before benchmarking`,
  );
}

await run(["go", "mod", "download"]);
await run([process.execPath, "install", "--frozen-lockfile"], frontend);
await run([
  wails,
  "generate",
  "bindings",
  "-clean",
  "-ts",
  "-i",
  "-f=-tags=libsqlite3,sqlite_omit_load_extension",
]);
await run([process.execPath, "run", "build"], frontend);

const sdk = await run(["xcrun", "--show-sdk-path"], repository);
await mkdir(resolve(application, "bin"), { recursive: true });
await run(
  [
    "go",
    "build",
    "-tags=production,libsqlite3,sqlite_omit_load_extension",
    "-trimpath",
    "-buildvcs=false",
    "-ldflags=-w -s",
    "-o",
    resolve(application, `bin/${executable}`),
    ".",
  ],
  application,
  {
    ...process.env,
    CGO_CFLAGS: "-mmacosx-version-min=11.0",
    CGO_CXXFLAGS: "-mmacosx-version-min=11.0",
    CGO_LDFLAGS: `-L${sdk}/usr/lib`,
  },
);

await rm(bundle, { recursive: true, force: true });
await Promise.all([
  mkdir(macos, { recursive: true }),
  mkdir(resources, { recursive: true }),
]);
await Promise.all([
  copyFile(resolve(application, `bin/${executable}`), resolve(macos, executable)),
  copyFile(resolve(application, "build/Info.plist"), resolve(bundle, "Contents/Info.plist")),
]);
await chmod(resolve(macos, executable), 0o755);

const iconTemp = await mkdtemp(join(tmpdir(), "z-notes-wails-icon-"));
try {
  const icon = await processIcon(resolve(repository, "assets/zapp.png"), iconTemp);
  await Promise.all(icon.files.map(({ src, dest }) => copyFile(src, resolve(resources, dest))));
} finally {
  await rm(iconTemp, { recursive: true, force: true });
}

await run(["codesign", "--force", "--deep", "--sign", "-", bundle], repository);
console.log(`packaged ${bundle}`);
