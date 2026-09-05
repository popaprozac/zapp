import { test, expect } from "bun:test";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  createConfigContext, defaultApplicationIdentifier, defineConfig, loadConfig,
  resolveNative, validateNative, validateWebEngine, resolveWebEngine,
  platformSupportsChromium, resolveWebEngineForBuild, validateWebviewInject,
  validateCapabilityProfiles, validateNavigationProfiles, validateWorkers,
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
          inject: {
            base: {
              styles: ["src/base.css"],
              documentStart: ["src/preload.ts"],
              documentEnd: ["src/ready.ts"],
            },
          },
        },
        workers: {
          application: {
            searchIndexer: {
              script: "src/workers/indexer.ts",
              engine: "zjs",
              capabilities: ["default"],
            },
          },
          modules: ["fetch"],
        },
        security: {
          permissions: ["clipboard:read", "window:create"],
          capabilities: {
            default: {
              permissions: ["window:create"],
              services: ["notes"],
            },
          },
          navigation: {
            default: {
              navigate: ["self", "https://docs.example.com"],
              openExternal: ["https:", "mailto:"],
            },
          },
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
    expect(config.webviewInject).toEqual({
      base: {
        styles: ["src/base.css"],
        documentStart: ["src/preload.ts"],
        documentEnd: ["src/ready.ts"],
      },
    });
    expect(config.applicationWorkers).toEqual({
      searchIndexer: {
        script: "src/workers/indexer.ts",
        engine: "zjs",
        capabilities: ["default"],
      },
    });
    expect(config.workerModules).toEqual(["fetch"]);
    expect(config.permissions).toEqual(["clipboard:read", "window:create"]);
    expect(config.capabilityProfiles).toEqual({
      default: {
        permissions: ["window:create"],
        services: ["notes"],
      },
    });
    expect(config.navigationProfiles).toEqual({
      default: {
        navigate: ["self", "https://docs.example.com"],
        openExternal: ["https:", "mailto:"],
      },
    });
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
    expect(snapshot.version).toBe(2);
    expect(snapshot.command).toBe("package");
    expect(snapshot.target.os).toBe("macos");
    expect(snapshot.config).toEqual(config);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("validateNavigationProfiles keeps WebView authority explicit and origin-shaped", () => {
  expect(() => validateNavigationProfiles({
    default: {
      navigate: ["self", "https://docs.example.com"],
      openExternal: ["https:", "mailto:"],
    },
    diagnostics: { navigate: ["self"] },
  })).not.toThrow();

  expect(() => validateNavigationProfiles({
    docs: { navigate: ["self"] },
  })).toThrow(/must declare a "default" profile/);
  expect(() => validateNavigationProfiles({
    default: { navigate: ["https://docs.example.com/guide"] },
  })).toThrow(/HTTP\(S\) origin without a path/);
  expect(() => validateNavigationProfiles({
    default: { navigate: ["https://docs.example.com", "https://docs.example.com/"] },
  })).toThrow(/repeats/);
  expect(() => validateNavigationProfiles({
    default: { openExternal: ["https"] },
  })).toThrow(/URL scheme ending in/);
  expect(() => validateNavigationProfiles({
    default: { navigate: ["self"], arbitrary: [] } as any,
  })).toThrow(/arbitrary is unknown/);
});

test("validateWorkers keeps runtime modules separate from native authority", () => {
  const profiles = {
    default: { services: ["notes"] },
    backgroundSearch: { services: ["notes.updateIndex"] },
  };
  expect(() => validateWorkers({
    application: {
      searchIndexer: {
        script: "src/workers/search-indexer.ts",
        engine: "zjs",
        capabilities: ["backgroundSearch"],
        protocol: {
          module: "src/workers/search-protocol.zs",
          type: "SearchProtocol",
        },
      },
    },
    modules: ["encoding"],
  }, profiles)).not.toThrow();

  expect(() => validateWorkers({
    application: {
      searchIndexer: {
        script: "src/workers/search-indexer.ts",
        capabilities: ["missing"],
      },
    },
  }, profiles)).toThrow(/unknown security capability profile "missing"/);

  expect(() => validateWorkers({
    application: {
      searchIndexer: {
        script: "src/workers/search-indexer.ts",
        capabilities: ["default", "default"],
      },
    },
  }, profiles)).toThrow(/capabilities repeats "default"/);

  expect(() => validateWorkers({
    modules: ["encoding", "encoding"],
  }, profiles)).toThrow(/workers.modules repeats "encoding"/);

  expect(() => validateWorkers({
    application: {
      searchIndexer: {
        script: "src/workers/search-indexer.ts",
        protocol: { module: "src/workers/search-protocol.zs", type: "SearchProtocol" },
      },
    },
  }, profiles)).not.toThrow();
  expect(() => validateWorkers({
    application: {
      searchIndexer: {
        script: "src/workers/search-indexer.ts",
        protocol: { module: "../search-protocol.zs", type: "SearchProtocol" },
      },
    },
  } as any, profiles)).toThrow(/protocol\.module must stay relative/);
  expect(() => validateWorkers({
    application: {
      searchIndexer: {
        script: "src/workers/search-indexer.ts",
        protocol: { module: "src/workers/search-protocol.ts", type: "SearchProtocol" },
      },
    },
  } as any, profiles)).toThrow(/protocol\.module must name a \.zs/);
  expect(() => validateWorkers({
    application: {
      searchIndexer: {
        script: "src/workers/search-indexer.ts",
        protocol: { module: "src/workers/search-protocol.zs", type: "Search.Protocol" },
      },
    },
  } as any, profiles)).toThrow(/protocol\.type must be a Z identifier/);
});

test("validateWorkers requires a bounded positive restart policy", () => {
  const valid = (restart: unknown) => validateWorkers({
    application: {
      indexer: {
        script: "src/workers/indexer.ts",
        restart,
      } as any,
    },
  });

  expect(() => valid({})).not.toThrow();
  expect(() => valid({ maxRetries: 2, withinMs: 5_000 })).not.toThrow();
  expect(() => valid(false)).not.toThrow();
  expect(() => valid({ maxRetries: 0 })).toThrow(/positive safe integer/);
  expect(() => valid({ withinMs: -1 })).toThrow(/positive safe integer/);
  expect(() => valid({ maxRetries: 1.5 })).toThrow(/positive safe integer/);
  expect(() => valid({ maxRetries: Number.MAX_VALUE })).toThrow(/positive safe integer/);
  expect(() => valid({ retries: 2 })).toThrow(/restart\.retries is unknown/);
  expect(() => valid(true)).toThrow(/must be false or an object/);
});

test("validateWebviewInject rejects ambiguous or escaping profile inputs", () => {
  expect(() => validateWebviewInject({ empty: {} })).toThrow(
    /must declare at least one file/,
  );
  expect(() => validateWebviewInject({
    "bad name": { documentStart: ["src/preload.ts"] },
  })).toThrow(/profile "bad name"/);
  expect(() => validateWebviewInject({
    base: { documentStart: ["../outside.ts"] },
  })).toThrow(/must stay relative/);
  expect(() => validateWebviewInject({
    base: { styles: ["src/base.css", "src/base.css"] },
  })).toThrow(/repeats/);
  expect(() => validateWebviewInject({
    base: { documentStart: ["src/preload.ts"], typo: ["x.ts"] } as any,
  })).toThrow(/typo is unknown/);
});

test("validateCapabilityProfiles requires explicit default and bounded grants", () => {
  expect(() => validateCapabilityProfiles({ diagnostics: {} }))
    .toThrow(/must declare a "default" profile/);
  expect(() => validateCapabilityProfiles({
    default: { permissions: ["window:create"], services: ["notes"] },
  }, []))
    .toThrow(/security.permissions does not include it/);
  expect(() => validateCapabilityProfiles({
    default: { services: ["notes", "notes"] },
  }))
    .toThrow(/repeats "notes"/);
  expect(() => validateCapabilityProfiles({
    default: { services: ["notes"] },
    diagnostics: { services: ["notes.count"] },
  })).not.toThrow();
  expect(() => validateCapabilityProfiles({
    default: { permissions: ["clipboard:read"] },
  }, ["clipboard:read"]))
    .not.toThrow();
  expect(() => validateCapabilityProfiles({
    default: { permissions: ["shell:open", "shell:reveal", "shell:trash"] },
  }, ["shell:open", "shell:reveal", "shell:trash"]))
    .not.toThrow();
  expect(() => validateCapabilityProfiles({
    default: { permissions: ["fs:read"] },
  }, ["fs:read"]))
    .toThrow(/currently supports "window:create", "menu", "notifications", shell access, clipboard access, and services/);
  expect(() => validateCapabilityProfiles({
    default: { permissions: ["menu"] },
  }, ["menu"])).not.toThrow();
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

test("capability worker grants must name configured application workers", () => {
  expect(() => validateWorkers(undefined, {
    default: { workers: ["indexer"] },
  })).toThrow(/workers\.application is absent/);
  expect(() => validateWorkers({
    application: { lifecycle: "./lifecycle.ts" },
  }, {
    default: { workers: ["indexer"] },
  })).toThrow(/unknown application worker "indexer"/);
  expect(() => validateWorkers({
    application: { indexer: "./indexer.ts" },
  }, {
    default: { workers: ["indexer"] },
  })).not.toThrow();
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
