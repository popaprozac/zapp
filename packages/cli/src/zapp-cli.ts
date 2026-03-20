#!/usr/bin/env bun
import path from "node:path";
import process from "node:process";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { runDev } from "./dev";
import { runBuild } from "./build";
import { runInit } from "./init";
import { runPackage } from "./package";
import { runGenerate } from "./generate";
import { loadConfig } from "./config";

const VALID_LOG_LEVELS = ["error", "warn", "info", "debug", "trace"] as const;
type LogLevel = typeof VALID_LOG_LEVELS[number];

const checkPrerequisites = () => {
  const which = Bun.which("zc");
  if (!which) {
    console.error(
      "[zapp] Error: 'zc' (Zen-C compiler) not found on PATH.\n" +
      "  Install from: https://github.com/zenc-lang/zenc\n"
    );
    process.exit(1);
  }
};

const cwd = process.cwd();

const commonOptions = {
  root: {
    type: "string" as const,
    default: ".",
    describe: "Project root directory",
  },
  frontend: {
    type: "string" as const,
    default: ".",
    describe: "Frontend directory",
  },
  input: {
    type: "string" as const,
    default: "zapp/build.zc",
    describe: "Build file (alias: --build-file)",
  },
  out: {
    type: "string" as const,
    describe: "Override output binary path",
  },
  backend: {
    type: "string" as const,
    describe: "Backend script path",
  },
  "log-level": {
    type: "string" as const,
    choices: VALID_LOG_LEVELS,
    describe: "Log level",
  },
} as const;

const cli = yargs(hideBin(process.argv))
  .scriptName("zapp")
  .usage("zapp <command> [options]")
  .strict()
  .demandCommand(1, "Please specify a command")
  .command(
    "init [name]",
    "Scaffold a new Zapp project",
    (yargs) =>
      yargs
        .positional("name", {
          type: "string",
          default: "zapp-app",
          describe: "Project name",
        })
        .option("template", {
          type: "string",
          default: "svelte-ts",
          describe: "Frontend template",
        })
        .option("backend", {
          type: "boolean",
          default: false,
          describe: "Include backend script",
        })
        .option("root", commonOptions.root),
    async (argv) => {
      const root = path.resolve(cwd, argv.root);
      await runInit({
        root,
        name: argv.name,
        template: argv.template,
        withBackend: argv.backend,
      });
    }
  )
  .command(
    "dev",
    "Run Vite + native app together",
    (yargs) =>
      yargs
        .option("root", commonOptions.root)
        .option("frontend", commonOptions.frontend)
        .option("input", commonOptions.input)
        .option("out", commonOptions.out)
        .option("backend", commonOptions.backend)
        .option("log-level", commonOptions["log-level"])
        .option("dev-url", {
          type: "string",
          default: "http://localhost:5173",
          describe: "Dev server URL",
        })
        .option("brotli", {
          type: "boolean",
          default: false,
          describe: "Brotli-compress embedded assets",
        })
        .option("embed-assets", {
          type: "boolean",
          default: false,
          describe: "Embed assets in binary (default: false for dev)",
        }),
    async (argv) => {
      checkPrerequisites();
      const root = path.resolve(cwd, argv.root);
      const frontendDir = path.resolve(root, argv.frontend);
      const buildFile = path.resolve(root, argv.input);
      const config = await loadConfig(root);
      const nativeOut = argv.out
        ? path.resolve(root, argv.out)
        : path.resolve(root, "bin", process.platform === "win32" ? `${config.name}.exe` : config.name);

      await runDev({
        root,
        frontendDir,
        buildFile,
        nativeOut,
        devUrl: argv["dev-url"],
        withBrotli: argv.brotli,
        embedAssets: argv["embed-assets"],
        backendScript: argv.backend,
        logLevel: argv["log-level"] as LogLevel | undefined,
        config,
      });
    }
  )
  .command(
    "build",
    "Build frontend assets + native binary",
    (yargs) =>
      yargs
        .option("root", commonOptions.root)
        .option("frontend", commonOptions.frontend)
        .option("input", commonOptions.input)
        .option("out", commonOptions.out)
        .option("backend", commonOptions.backend)
        .option("log-level", commonOptions["log-level"])
        .option("asset-dir", {
          type: "string",
          default: "dist",
          describe: "Asset directory",
        })
        .option("brotli", {
          type: "boolean",
          default: false,
          describe: "Brotli-compress embedded assets",
        })
        .option("debug", {
          type: "boolean",
          default: false,
          describe: "Debug build (filesystem assets, debug logs, no optimizations)",
        }),
    async (argv) => {
      checkPrerequisites();
      const root = path.resolve(cwd, argv.root);
      const frontendDir = path.resolve(root, argv.frontend);
      const buildFile = path.resolve(root, argv.input);
      const assetDir = path.resolve(frontendDir, argv["asset-dir"]);
      const config = await loadConfig(root);
      const nativeOut = argv.out
        ? path.resolve(root, argv.out)
        : path.resolve(root, "bin", process.platform === "win32" ? `${config.name}.exe` : config.name);

      // Embed assets by default for builds, unless --debug
      const embedAssets = !argv.debug;

      await runBuild({
        root,
        frontendDir,
        buildFile,
        nativeOut,
        assetDir,
        withBrotli: argv.brotli,
        embedAssets,
        isDebug: argv.debug,
        backendScript: argv.backend,
        logLevel: argv["log-level"] as LogLevel | undefined,
        config,
      });
    }
  )
  .command(
    "package",
    "Package the binary into a macOS .app bundle",
    (yargs) =>
      yargs
        .option("root", commonOptions.root)
        .option("out", commonOptions.out),
    async (argv) => {
      checkPrerequisites();
      const root = path.resolve(cwd, argv.root);
      const config = await loadConfig(root);
      const nativeOut = argv.out
        ? path.resolve(root, argv.out)
        : path.resolve(root, "bin", process.platform === "win32" ? `${config.name}.exe` : config.name);

      await runPackage({ root, nativeOut, config });
    }
  )
  .command(
    "generate",
    "Generate TypeScript bindings from Zen-C services",
    (yargs) =>
      yargs
        .option("root", commonOptions.root)
        .option("frontend", commonOptions.frontend)
        .option("out-dir", {
          type: "string",
          describe: "Output directory for generated files",
        }),
    async (argv) => {
      const root = path.resolve(cwd, argv.root);
      const frontendDir = path.resolve(root, argv.frontend);
      await runGenerate({ root, frontendDir, outDir: argv["out-dir"] });
    }
  )
  .alias("h", "help")
  .alias("v", "version")
  .alias("build-file", "input")
  .epilogue("Documentation: https://zapp.dev")
  .parse();
