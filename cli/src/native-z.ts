import path from "node:path";
import { existsSync } from "node:fs";
import { cp, mkdir, readFile } from "node:fs/promises";
import type { BuildTarget } from "./build-target";

export interface ZCompilerIdentity {
  languageVersion: string;
  compilerRevision: string;
  compilerApi: number;
}

interface ZCompilerContract extends ZCompilerIdentity {}

interface BuildNativeZOptions {
  root: string;
  nativeDir: string;
  output: string;
  optimize: boolean;
  target: BuildTarget;
}

export function parseZCompilerIdentity(output: string): ZCompilerIdentity {
  const match = output.trim().match(
    /^z\s+(\S+)\s+revision\s+(\S+)\s+compiler-api\s+(\d+)$/,
  );
  if (!match) {
    throw new Error(
      `[zapp] could not parse Z compiler identity ${JSON.stringify(output.trim())}. ` +
      "Zapp requires a compiler that supports `z version`.",
    );
  }
  return {
    languageVersion: match[1],
    compilerRevision: match[2],
    compilerApi: Number(match[3]),
  };
}

export function validateZCompilerIdentity(
  expected: ZCompilerIdentity,
  actual: ZCompilerIdentity,
  contractPath: string,
): void {
  const differences: string[] = [];
  if (actual.languageVersion !== expected.languageVersion) {
    differences.push(`language ${actual.languageVersion} (expected ${expected.languageVersion})`);
  }
  if (actual.compilerRevision !== expected.compilerRevision) {
    differences.push(`revision ${actual.compilerRevision} (expected ${expected.compilerRevision})`);
  }
  if (actual.compilerApi !== expected.compilerApi) {
    differences.push(`compiler API ${actual.compilerApi} (expected ${expected.compilerApi})`);
  }
  if (differences.length > 0) {
    throw new Error(
      `[zapp] incompatible Z compiler: ${differences.join(", ")}. ` +
      `Use the compiler pinned by ${contractPath} or update the contract after validating Zapp.`,
    );
  }
}

export function resolveZCompiler(repositoryRoot: string): string {
  if (process.env.ZAPP_Z_COMPILER) return process.env.ZAPP_Z_COMPILER;
  const sibling = path.resolve(repositoryRoot, "../z-lang/.z-cache/bootstrap/z");
  return existsSync(sibling) ? sibling : "z";
}

async function run(command: string[], cwd: string, capture = false): Promise<string> {
  const process = Bun.spawn(command, {
    cwd,
    stdout: capture ? "pipe" : "inherit",
    stderr: capture ? "pipe" : "inherit",
  });
  const stdout = capture ? await new Response(process.stdout).text() : "";
  const stderr = capture ? await new Response(process.stderr).text() : "";
  const status = await process.exited;
  if (status !== 0) {
    throw new Error(
      `[zapp] command failed (${status}): ${command.join(" ")}` +
      (stderr.trim() ? `\n${stderr.trim()}` : ""),
    );
  }
  return stdout;
}

export async function assertZCompilerContract(
  compiler: string,
  contractPath: string,
  cwd: string,
): Promise<ZCompilerIdentity> {
  const expected = JSON.parse(await readFile(contractPath, "utf8")) as ZCompilerContract;
  const actual = parseZCompilerIdentity(await run([compiler, "version"], cwd, true));
  validateZCompilerIdentity(expected, actual, contractPath);
  return actual;
}

export async function buildNativeZ(options: BuildNativeZOptions): Promise<void> {
  if (options.target !== "macos") {
    throw new Error(
      `[zapp] the Phase 0 Z native core currently supports target "macos", not ${JSON.stringify(options.target)}.`,
    );
  }

  const source = path.join(options.nativeDir, "z");
  const stage = path.join(options.root, ".zapp", "z-native-core");
  await mkdir(stage, { recursive: true });
  for (const file of [
    "core.zs",
    "z.json",
    "zapp_router.h",
    "zapp_router.h.zd",
    "host.c",
  ]) {
    await cp(path.join(source, file), path.join(stage, file));
  }

  const compiler = resolveZCompiler(path.resolve(options.nativeDir, ".."));
  const identity = await assertZCompilerContract(
    compiler,
    path.join(source, "compiler-contract.json"),
    options.root,
  );
  console.log(
    `[zapp] Z core compiler ${identity.languageVersion} ` +
    `(revision ${identity.compilerRevision}, API ${identity.compilerApi})`,
  );

  await run(
    [compiler, "build", stage, ...(options.optimize ? ["--release"] : [])],
    options.root,
  );

  await mkdir(path.dirname(options.output), { recursive: true });
  const archive = path.join(stage, "build", "libzapp_core.a");
  const headerDir = path.join(stage, "build");
  const clang = process.env.CC || "clang";
  await run([
    clang,
    "-std=c11",
    options.optimize ? "-Oz" : "-O0",
    "-Wall",
    "-Wextra",
    "-Werror",
    "-I",
    headerDir,
    path.join(stage, "host.c"),
    archive,
    "-o",
    options.output,
  ], options.root);
}
