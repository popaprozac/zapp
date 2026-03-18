import { spawn, spawnSync, execSync, type ChildProcess } from "node:child_process";
import path from "node:path";
import { existsSync, statSync } from "node:fs";
import { mkdir } from "node:fs/promises";
import process from "node:process";

export const sleep = (ms: number) => Bun.sleep(ms);

let _nativeDir: string | null = null;

export const resolveNativeDir = (): string => {
  if (_nativeDir) return _nativeDir;

  const cliSrcDir = import.meta.dir;
  const cliRoot = path.dirname(cliSrcDir);

  // Monorepo: packages/cli/../../ is the repo root with src/ and vendor/
  const repoRoot = path.resolve(cliRoot, "../..");
  if (existsSync(path.join(repoRoot, "src")) && existsSync(path.join(repoRoot, "vendor"))) {
    _nativeDir = repoRoot;
    return _nativeDir;
  }

  // Published/linked: packages/cli/native/ exists
  const bundled = path.join(cliRoot, "native");
  if (existsSync(path.join(bundled, "src")) && existsSync(path.join(bundled, "vendor"))) {
    _nativeDir = bundled;
    return _nativeDir;
  }

  throw new Error(
    "[zapp] Cannot find native framework code. Expected either:\n" +
    `  - ${repoRoot}/src  (monorepo development)\n` +
    `  - ${bundled}/src  (bundled with CLI)\n`
  );
};

export const nativeIncludeArgs = (): string[] => {
  const nd = resolveNativeDir();
  const args: string[] = [];

  args.push("-I", path.join(nd, "src"));
  args.push("-I", path.join(nd, "vendor", "quickjs-ng"));

  if (process.platform === "win32") {
    args.push("-I", path.join(nd, "vendor", "webview2", "include"));
  }

  return args;
};

/**
 * Compile QuickJS source into a static library (.a) if needed.
 * Returns the path to the library, or null if the build dir isn't ready.
 * The library is cached in .zapp/qjs/ and only rebuilt when source changes.
 */
export const ensureQjsLib = async (root: string): Promise<string> => {
  const nd = resolveNativeDir();
  const qjsVendor = path.join(nd, "vendor", "quickjs-ng");
  const qjsBuildDir = path.join(root, ".zapp", "qjs");
  await mkdir(qjsBuildDir, { recursive: true });

  const libPath = path.join(qjsBuildDir, "libqjs.a");
  const sourceFiles = ["quickjs.c", "quickjs-libc.c", "dtoa.c", "libregexp.c", "libunicode.c"];

  const libExists = existsSync(libPath);
  let needsRebuild = !libExists;
  if (libExists) {
    const libMtime = statSync(libPath).mtimeMs;
    for (const src of sourceFiles) {
      const srcPath = path.join(qjsVendor, src);
      if (existsSync(srcPath) && statSync(srcPath).mtimeMs > libMtime) {
        needsRebuild = true;
        break;
      }
    }
  }

  if (!needsRebuild) return libPath;

  process.stdout.write("[zapp] compiling QuickJS...\n");

  const cc = process.platform === "win32" ? "gcc" : "cc";
  const cflags = ["-Oz", "-flto", "-c", `-I${qjsVendor}`];
  if (process.platform === "win32") {
    cflags.push("-DUNICODE", "-D_UNICODE");
  }

  const objectFiles: string[] = [];
  for (const src of sourceFiles) {
    const srcPath = path.join(qjsVendor, src);
    const objPath = path.join(qjsBuildDir, src.replace(".c", ".o"));
    objectFiles.push(objPath);
    await runCmd(cc, [...cflags, srcPath, "-o", objPath]);
  }

  const ar = process.platform === "win32" ? "gcc-ar" : "ar";
  await runCmd(ar, ["rcs", libPath, ...objectFiles]);

  return libPath;
};

let cachedExec: string | null = null;

export const preferredJsTool = (): string => {
  if (cachedExec) return cachedExec;
  if (Bun.which("bun")) {
    cachedExec = "bun";
    return cachedExec;
  }
  cachedExec = "npm";
  return cachedExec;
};

export const runCmd = async (command: string, args: string[], options: any = {}) => {
  const { $ } = require("bun");
  const env = { ...process.env, ...(options.env ?? {}) };
  const cwd = options.cwd ?? process.cwd();
  
  if (command === "zc") {
    console.error(`[debug] zc ${args.join(" ")}`);
  }
  
  if (command === "bun") {
    await $`bun ${args}`.cwd(cwd).env(env);
  } else if (command === "zc") {
    await $`zc ${args}`.cwd(cwd).env(env);
  } else {
    const cmdPath = Bun.which(command) || command;
    const proc = Bun.spawn([cmdPath, ...args], {
      cwd,
      stdio: ["inherit", "inherit", "inherit"],
      env,
    });
    const code = await proc.exited;
    if (code !== 0) {
      throw new Error(`${command} ${args.join(" ")} failed (${code})`);
    }
  }
};

export const spawnStreaming = (command: string, args: string[], options: any = {}) => {
  const cmdPath = Bun.which(command) || command;
  return Bun.spawn([cmdPath, ...args], {
    cwd: options.cwd ?? process.cwd(),
    stdio: ["inherit", "inherit", "inherit"],
    env: { ...process.env, ...(options.env ?? {}) },
  });
};

export const killChild = (child: import("bun").Subprocess | null | any) => {
  if (!child || child.killed) return;
  const pid = child.pid;
  if (process.platform === "win32" && pid) {
    try {
      execSync(`taskkill /F /T /PID ${pid}`, { stdio: "ignore" });
      return;
    } catch { /* process may already be gone */ }
  }
  try {
    child.kill("SIGTERM");
  } catch {
    try { child.kill(9); } catch { /* ignore */ }
  }
};

export const runPackageScript = (script: string, options: any = {}) => {
  const tool = preferredJsTool();
  const args = tool === "bun" ? ["run", script] : ["run", script];
  return runCmd(tool, args, options);
};

export const spawnPackageScript = (script: string, options: any = {}) => {
  const tool = preferredJsTool();
  const args = tool === "bun" ? ["run", script] : ["run", script];
  return spawnStreaming(tool, args, options);
};
