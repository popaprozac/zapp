import { test, expect } from "bun:test";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  createConfigContext, defaultApplicationIdentifier, defineConfig, loadConfig,
  resolveNative, validateNative, validateWebEngine, resolveWebEngine,
  platformSupportsChromium, resolveWebEngineForBuild,
} from "./config";

test("defaultApplicationIdentifier produces a stable reverse-DNS-safe identifier", () => {
  expect(defaultApplicationIdentifier("  Z Notes!  ")).toBe("com.zapp.z-notes");
  expect(defaultApplicationIdentifier("世界")).toBe("com.zapp.app");
});

test("defineConfig preserves object and contextual factory definitions", () => {
  const object = { application: { name: "notes" } };
  const factory = (context: ReturnType<typeof createConfigContext>) => ({
    application: { name: context.mode },
  });
  expect(defineConfig(object)).toBe(object);
  expect(defineConfig(factory)).toBe(factory);
});

test("createConfigContext exposes command, mode, target, and project root", () => {
  const context = createConfigContext(".", "dev", "ios-simulator");
  expect(context.command).toBe("dev");
  expect(context.mode).toBe("development");
  expect(context.target.os).toBe("ios");
  expect(context.target.environment).toBe("simulator");
  expect(["arm64", "x64"]).toContain(context.target.arch);
  expect(path.isAbsolute(context.root)).toBe(true);
});

test("loadConfig evaluates a contextual factory and writes the resolved snapshot", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "zapp-config-context-"));
  try {
    await writeFile(path.join(root, "zapp.config.ts"), `
      export default async (context) => ({
        application: {
          name: context.command + "-" + context.target.os,
          identifier: "com.example.notes",
          version: "1.2.3",
          singleInstance: true,
          deepLinks: ["notes"],
        },
        frontend: {
          assets: "./web-dist",
          devServer: { port: context.mode === "development" ? 4100 : 4200 },
          compressAssets: false,
        },
        webview: {
          engine: { macOS: "chromium", windows: "system" },
          protocols: ["asset"],
          preferences: { minimumFontSize: 14 },
        },
        workers: {
          headless: { indexer: "src/workers/indexer.ts" },
          capabilities: ["fetch"],
        },
        security: {
          permissions: ["clipboard:read"],
          filesystem: { allow: ["$userData"] },
        },
        native: {
          frameworks: { macOS: ["AppKit"] },
          linkFlags: ["-lsqlite3"],
          sources: ["native/helper.m"],
        },
        targets: {
          macOS: { minimumSystemVersion: "14.0" },
          iOS: { minimumSystemVersion: "17.0" },
        },
      });
    `);
    const relativeRoot = path.relative(process.cwd(), root);
    const context = createConfigContext(relativeRoot, "package", "macos");
    const config = await loadConfig(relativeRoot, context);
    expect(config.name).toBe("package-macos");
    expect(config.identifier).toBe("com.example.notes");
    expect(config.version).toBe("1.2.3");
    expect(config.singleInstance).toBe(true);
    expect(config.devPort).toBe(4200);
    expect(config.assetDir).toBe("./web-dist");
    expect(config.compressAssets).toBe(false);
    expect(config.deepLinkSchemes).toEqual(["notes"]);
    expect(config.webEngine).toEqual({ macOS: "chromium", windows: "system" });
    expect(config.protocols).toEqual(["asset"]);
    expect(config.webviewPreferences).toEqual({ minimumFontSize: 14 });
    expect(config.headless).toEqual({ indexer: "src/workers/indexer.ts" });
    expect(config.workerModules).toEqual(["fetch"]);
    expect(config.permissions).toEqual(["clipboard:read"]);
    expect(config.fs).toEqual({ allow: ["$userData"] });
    expect(config.native).toEqual({
      frameworks: { macOS: ["AppKit"] },
      linkFlags: ["-lsqlite3"],
      sources: ["native/helper.m"],
    });
    expect(config.macos).toEqual({ minimumSystemVersion: "14.0" });
    expect(config.ios).toEqual({ minimumSystemVersion: "17.0" });

    const snapshot = JSON.parse(
      await readFile(path.join(root, ".zapp", "config.resolved.json"), "utf8"),
    );
    expect(snapshot.version).toBe(1);
    expect(snapshot.command).toBe("package");
    expect(snapshot.target.os).toBe("macos");
    expect(snapshot.config).toEqual(config);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("loadConfig resolves canonical application identity defaults", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "zapp-config-defaults-"));
  try {
    await writeFile(path.join(root, "zapp.config.ts"), `
      export default { application: { name: "  Example Notes!  " } };
    `);
    const config = await loadConfig(
      root,
      createConfigContext(root, "build", "macos"),
    );
    expect(config.name).toBe("Example Notes!");
    expect(config.identifier).toBe("com.zapp.example-notes");
    expect(config.version).toBe("0.1.0");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("loadConfig rejects values that cannot enter the resolved build contract", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "zapp-config-invalid-"));
  try {
    await writeFile(path.join(root, "zapp.config.ts"), `
      export default {
        application: { name: "invalid" },
        native: { sources: [() => "not serializable"] },
      };
    `);
    await expect(
      loadConfig(root, createConfigContext(root, "build", "macos")),
    ).rejects.toThrow(/must be serializable/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("resolveNative reads the grouped native block", () => {
  const cfg = { native: { frameworks: ["CoreLocation"], linkFlags: ["-lfoo"], sources: ["a.m"] } } as any;
  expect(resolveNative(cfg, "macos")).toEqual({
    frameworks: ["CoreLocation"], linkFlags: ["-lfoo"], sources: ["a.m"],
  });
});

test("resolveNative resolves per-platform PlatformValue maps for the target", () => {
  const cfg = { native: { frameworks: { macOS: ["MacFW"], iOS: ["IosFW"] } } } as any;
  expect(resolveNative(cfg, "macos").frameworks).toEqual(["MacFW"]);
  expect(resolveNative(cfg, "ios-simulator").frameworks).toEqual(["IosFW"]);
});

test("resolveNative returns empty arrays when nothing is set", () => {
  expect(resolveNative({} as any, "macos")).toEqual({ frameworks: [], linkFlags: [], sources: [] });
});

test("validateNative accepts arrays + per-platform maps", () => {
  expect(() => validateNative({ native: { frameworks: ["A"], linkFlags: ["-lx"] } } as any)).not.toThrow();
  expect(() => validateNative({ native: { frameworks: { macOS: ["A"], iOS: ["B"] } } } as any)).not.toThrow();
  expect(() => validateNative({} as any)).not.toThrow();
});

test("validateNative rejects a non-array / non-map value", () => {
  expect(() => validateNative({ native: { frameworks: "CoreLocation" } } as any)).toThrow(/native\.frameworks/);
});

test("validateNative rejects non-string array entries", () => {
  expect(() => validateNative({ native: { linkFlags: [1, 2] } } as any)).toThrow(/native\.linkFlags/);
});

test("validateNative rejects misspelled platform keys", () => {
  expect(() => validateNative({ native: { frameworks: { macos: ["A"] } } } as any))
    .toThrow(/use macOS, iOS, windows, or linux/);
});

// webEngine: "chromium" is now an accepted early-access opt-in (CEF
// production slice) — it silently accepts (no throw), no longer warns here.
// "system"/unset stay the default; unknown values still throw. See
// resolveWebEngine below for the single-source-of-truth resolver the build +
// window creation both read.
test("validateWebEngine accepts \"chromium\" (no throw, no longer warns)", () => {
  expect(() => validateWebEngine("chromium")).not.toThrow();
});

test("validateWebEngine accepts \"system\" and unset", () => {
  expect(() => validateWebEngine("system")).not.toThrow();
  expect(() => validateWebEngine(undefined)).not.toThrow();
});

test("validateWebEngine still rejects unknown values", () => {
  expect(() => validateWebEngine("blink" as any)).toThrow(/webview\.engine/);
});

// --- resolveWebEngine: string form applies to every target ---
test("resolveWebEngine string form applies to all targets", () => {
  expect(resolveWebEngine({ webEngine: "chromium" } as any, "macos")).toBe("chromium");
  expect(resolveWebEngine({ webEngine: "chromium" } as any, "windows")).toBe("chromium");
  expect(resolveWebEngine({ webEngine: "system" } as any, "macos")).toBe("system");
});

test("resolveWebEngine defaults to system when unset", () => {
  expect(resolveWebEngine({} as any, "macos")).toBe("system");
  expect(resolveWebEngine({} as any, "windows")).toBe("system");
});

// --- resolveWebEngine: map form resolves per platform, missing key => system ---
test("resolveWebEngine map form resolves per platform", () => {
  const cfg = { webEngine: { macOS: "chromium", windows: "system" } } as any;
  expect(resolveWebEngine(cfg, "macos")).toBe("chromium");
  expect(resolveWebEngine(cfg, "windows")).toBe("system");
});

test("resolveWebEngine map form: missing key defaults to system", () => {
  const cfg = { webEngine: { macOS: "chromium" } } as any; // no windows/iOS key
  expect(resolveWebEngine(cfg, "windows")).toBe("system");
  expect(resolveWebEngine(cfg, "ios-simulator")).toBe("system");
});

test("resolveWebEngine collapses both iOS subtargets to the iOS key", () => {
  const cfg = { webEngine: { iOS: "chromium" } } as any;
  expect(resolveWebEngine(cfg, "ios-simulator")).toBe("chromium");
  expect(resolveWebEngine(cfg, "ios-device")).toBe("chromium");
});

// --- platformSupportsChromium: macOS only today ---
test("platformSupportsChromium is macOS-only today", () => {
  expect(platformSupportsChromium("macos")).toBe(true);
  expect(platformSupportsChromium("windows")).toBe(false);
  expect(platformSupportsChromium("ios-simulator")).toBe(false);
  expect(platformSupportsChromium("ios-device")).toBe(false);
});

// --- resolveWebEngineForBuild: downgrade chromium -> system on unsupported target ---
test("resolveWebEngineForBuild keeps chromium on macOS", () => {
  expect(resolveWebEngineForBuild({ webEngine: "chromium" } as any, "macos"))
    .toEqual({ engine: "chromium", downgraded: false });
});

test("resolveWebEngineForBuild downgrades chromium to system on an unsupported target", () => {
  expect(resolveWebEngineForBuild({ webEngine: { windows: "chromium" } } as any, "windows"))
    .toEqual({ engine: "system", downgraded: true });
});

test("resolveWebEngineForBuild leaves system alone everywhere", () => {
  expect(resolveWebEngineForBuild({} as any, "windows"))
    .toEqual({ engine: "system", downgraded: false });
});

// --- validateWebEngine: accepts string + map, throws on garbage ---
test("validateWebEngine accepts string and map forms", () => {
  expect(() => validateWebEngine("chromium")).not.toThrow();
  expect(() => validateWebEngine("system")).not.toThrow();
  expect(() => validateWebEngine(undefined)).not.toThrow();
  expect(() => validateWebEngine({ macOS: "chromium", windows: "system" } as any)).not.toThrow();
});

test("validateWebEngine throws on a garbage value in either form", () => {
  expect(() => validateWebEngine("blink" as any)).toThrow(/webview\.engine/);
  expect(() => validateWebEngine({ windows: "blink" } as any)).toThrow(/webview\.engine/);
  expect(() => validateWebEngine({ macos: "system" } as any))
    .toThrow(/use macOS, iOS, windows, or linux/);
});
