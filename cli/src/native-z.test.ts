import { describe, expect, it } from "bun:test";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  parseZCompilerIdentity,
  preparedZServicesAreCurrent,
  renderZApplicationMetadata,
  renderZConfiguredDesktopSmoke,
  renderZConfiguredWebView,
  renderZWebviewBootstrapConfig,
  renderZNativeManifest,
  rebaseZServiceManifest,
  resolveZFrontendOrigin,
  resolveZApplicationWorkerArtifact,
  resolveZNativeHost,
  validateZCompilerIdentity,
  zNativeEntry,
  zNativeStageFiles,
  zProgramInputPaths,
} from "./native-z";
import type { ZServiceManifest } from "./z-service-bindings";
import type { ZProgramMetadata } from "./z-program-metadata";

describe("Z application-worker artifacts", () => {
  it("selects Vite's live worker output in development", () => {
    expect(resolveZApplicationWorkerArtifact(
      "/project",
      "./dist",
      "/_workers/_headless_indexer.mjs",
      true,
    )).toBe("/project/.zapp/workers/_headless_indexer.mjs");
  });

  it("selects packaged worker assets for production", () => {
    expect(resolveZApplicationWorkerArtifact(
      "/project",
      "./dist",
      "/_workers/_headless_indexer.mjs",
      false,
    )).toBe("/project/dist/_workers/_headless_indexer.mjs");
  });

  it("rejects a development worker outside the plugin-owned URL namespace", () => {
    expect(() => resolveZApplicationWorkerArtifact(
      "/project",
      "./dist",
      "/worker.mjs",
      true,
    )).toThrow('must begin with "/_workers/"');
  });
});

describe("prepared Z service metadata", () => {
  const manifest: ZServiceManifest = {
    schemaVersion: 5,
    types: [{ name: "Request", module: "/repo/app/zapp/types.zs", fields: [] }],
    enums: [{ name: "State", module: "/repo/app/zapp/types.zs", variants: [] }],
    errors: [{ name: "Failure", module: "/repo/app/zapp/errors.zs", fields: [] }],
    services: [{
      name: "notes",
      type: "NotesService",
      kind: "struct",
      module: "/repo/app/zapp/notes.zs",
      lifecycle: false,
      registration: {
        module: "/repo/app/zapp/main.zs",
        offset: 42,
        line: 3,
        column: 2,
        method: "ApplicationServices.register",
      },
      methods: [],
    }],
  };

  it("rebases every source-bearing manifest field into the isolated workspace", () => {
    const rebased = rebaseZServiceManifest(manifest, [{
      source: "/repo/app/zapp",
      destination: "/stage/workspace/app/zapp",
    }]);

    expect(rebased.types[0].module).toBe("/stage/workspace/app/zapp/types.zs");
    expect(rebased.enums[0].module).toBe("/stage/workspace/app/zapp/types.zs");
    expect(rebased.errors[0].module).toBe("/stage/workspace/app/zapp/errors.zs");
    expect(rebased.services[0].module).toBe("/stage/workspace/app/zapp/notes.zs");
    expect(rebased.services[0].registration.module)
      .toBe("/stage/workspace/app/zapp/main.zs");
    expect(manifest.services[0].module).toBe("/repo/app/zapp/notes.zs");
  });

  it("fails closed when prepared evidence names a module outside the staged graph", () => {
    expect(() => rebaseZServiceManifest(manifest, [{
      source: "/different/repository",
      destination: "/stage/workspace",
    }])).toThrow(/outside the staged source graph/);
  });

  it("invalidates prepared evidence when any checked module changes or disappears", async () => {
    const directory = await mkdtemp(path.join(tmpdir(), "zapp-prepared-services-"));
    const modulePath = path.join(directory, "service.zs");
    const source = "export struct Service {}\n";
    try {
      await writeFile(modulePath, source, "utf8");
      const prepared = {
        bindingPath: path.join(directory, "services.ts"),
        manifest,
        programMetadataSource: "{}",
        inputHashes: {
          [modulePath]: createHash("sha256").update(source).digest("hex"),
        },
      };
      expect(await preparedZServicesAreCurrent(prepared)).toBe(true);
      await writeFile(modulePath, `${source}// changed\n`, "utf8");
      expect(await preparedZServicesAreCurrent(prepared)).toBe(false);
      await rm(modulePath);
      expect(await preparedZServicesAreCurrent(prepared)).toBe(false);
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  it("tracks package manifests and explicit compiler contracts as cache inputs", async () => {
    const directory = await mkdtemp(path.join(tmpdir(), "zapp-program-inputs-"));
    const packageDirectory = path.join(directory, "package");
    const sourceDirectory = path.join(packageDirectory, "src");
    const modulePath = path.join(sourceDirectory, "service.zs");
    const manifestPath = path.join(packageDirectory, "z.json");
    const contractPath = path.join(directory, "compiler-contract.json");
    try {
      await mkdir(sourceDirectory, { recursive: true });
      await Promise.all([
        writeFile(modulePath, "export struct Service {}\n", "utf8"),
        writeFile(manifestPath, "{}\n", "utf8"),
        writeFile(contractPath, "{}\n", "utf8"),
      ]);
      const metadata: ZProgramMetadata = {
        schemaVersion: 1,
        entry: 0,
        modules: [{ path: modulePath, symbols: [], calls: [] }],
      };
      expect(zProgramInputPaths(metadata, [contractPath])).toEqual([
        contractPath,
        manifestPath,
        modulePath,
      ].sort());
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });
});

describe("renderZConfiguredDesktopSmoke", () => {
  it("keeps production builds free of the smoke environment probe", () => {
    const source = renderZConfiguredDesktopSmoke(false);
    expect(source).toContain("return false");
    expect(source).not.toContain("getenv");
    expect(source).not.toContain("smoke.zapp_desktop_smoke_start_window(");
    expect(source).not.toContain("smoke.zapp_desktop_smoke_observe_response(");
    expect(source).not.toContain('import smoke from "desktop-smoke.h"');
  });

  it("enables smoke behavior only in the generated test build", () => {
    const source = renderZConfiguredDesktopSmoke(true);
    expect(source).toContain("return true");
    expect(source).not.toContain("getenv");
    expect(source).toContain("smoke.zapp_desktop_smoke_start_window(");
    expect(source).toContain("smoke.zapp_desktop_smoke_observe_response(");
    expect(source).toContain('import smoke from "desktop-smoke.h"');
  });
});

describe("renderZApplicationMetadata", () => {
  it("emits resolved immutable application metadata as valid Z literals", () => {
    const output = renderZApplicationMetadata({
      name: 'Notes "Preview"',
      identifier: "com.example.notes",
      version: "1.2.3",
      assetDir: "./dist",
    });
    expect(output).toContain('name: "Notes \\"Preview\\""');
    expect(output).toContain('identifier: "com.example.notes"');
    expect(output).toContain('version: "1.2.3"');
    expect(output).toContain("configuredApplicationMetadata");
    expect(output).toContain("configuredApplicationPermissions");
    expect(output).toContain("windowCreate: true");
    expect(output).toContain("clipboardRead: false");
    expect(output).toContain("clipboardWrite: false");
    expect(output).toContain("notifications: false");
    expect(output).toContain("shellOpen: false");
  });

  it("compiles an explicit window-create denial into native Z policy", () => {
    const output = renderZApplicationMetadata({
      name: "Locked",
      identifier: "com.example.locked",
      version: "1.0.0",
      assetDir: "./dist",
      permissions: [],
    });
    expect(output).toContain("windowCreate: false");
  });

  it("requires explicit clipboard grants in generated native Z policy", () => {
    const output = renderZApplicationMetadata({
      name: "Clipboard",
      identifier: "com.example.clipboard",
      version: "1.0.0",
      assetDir: "./dist",
      permissions: ["clipboard:read"],
    });
    expect(output).toContain("clipboardRead: true");
    expect(output).toContain("clipboardWrite: false");
  });

  it("requires an explicit notification grant in generated native Z policy", () => {
    const output = renderZApplicationMetadata({
      name: "Notifications",
      identifier: "com.example.notifications",
      version: "1.0.0",
      assetDir: "./dist",
      permissions: ["notifications"],
    });
    expect(output).toContain("notifications: true");
  });

  it("requires an explicit shell-open grant in generated native Z policy", () => {
    const output = renderZApplicationMetadata({
      name: "External Links",
      identifier: "com.example.external-links",
      version: "1.0.0",
      assetDir: "./dist",
      permissions: ["shell:open"],
    });
    expect(output).toContain("shellOpen: true");
  });

  it("emits exact immutable capability grants into native Z", () => {
    const output = renderZApplicationMetadata({
      name: "Scoped",
      identifier: "com.example.scoped",
      version: "1.0.0",
      assetDir: "./dist",
    }, [{
      name: "diagnostics",
      permissions: [],
      serviceMethods: ["notes.count"],
      workerIds: ["indexer"],
    }]);
    expect(output).toContain("configuredApplicationCapabilities");
    expect(output).toContain('profiles.set("diagnostics", CapabilityProfile({');
    expect(output).toContain('serviceMethods0.push("notes.count");');
    expect(output).toContain('workerIds0.push("indexer");');
    expect(output).toContain("serviceMethods: serviceMethods0.freeze()");
    expect(output).toContain("workerIds: workerIds0.freeze()");
  });

  it("embeds the checked application-worker catalog into native Z", () => {
    const output = renderZApplicationMetadata({
      name: "Workers",
      identifier: "com.example.workers",
      version: "1.0.0",
      assetDir: "./dist",
    }, [], [{
      id: "indexer",
      script: "src/workers/indexer.ts",
      moduleUrl: "/_workers/_headless_indexer.mjs",
      name: "Search indexer",
      engine: "zjs",
      bytecode: false,
      restart: { maxRetries: 3, withinMs: 60_000 },
      capabilities: ["search"],
      permissions: ["fs:read"],
      serviceMethods: ["notes.list"],
    }]);
    expect(output).toContain("configuredApplicationWorkers");
    expect(output).toContain('id: "indexer"');
    expect(output).toContain("engine: ApplicationWorkerEngine.zjs");
    expect(output).toContain('worker0Capabilities.push("search")');
    expect(output).toContain('worker0Permissions.push("fs:read")');
    expect(output).toContain('worker0ServiceMethods.push("notes.list")');
    expect(output).toContain("export function startConfiguredApplicationWorkers(");
    expect(output).toContain(
      'embed.bytes("./worker/generated/application-worker-0.mjs")',
    );
    expect(output).toContain("startZjsApplicationWorker(");
  });
});

describe("renderZWebviewBootstrapConfig", () => {
  it("mirrors resolved permissions for friendly frontend diagnostics", () => {
    const source = renderZWebviewBootstrapConfig({
      name: "Notes",
      identifier: "com.example.notes",
      version: "1.0.0",
      assetDir: "./dist",
      permissions: ["window:create"],
    }, "macos");
    expect(source).toContain('Symbol.for("zapp.bootstrapConfig")');
    expect(source).toContain('"platform":"macos"');
    expect(source).toContain('"active":true');
    expect(source).toContain('"allow":["window:create"]');
  });
});

describe("Z frontend origin", () => {
  it("uses one packaged application origin and normalizes development URLs", () => {
    expect(resolveZFrontendOrigin()).toBe("zapp://app/");
    expect(resolveZFrontendOrigin("http://localhost:5173"))
      .toBe("http://localhost:5173/");
    expect(resolveZFrontendOrigin("https://localhost:5173/app"))
      .toBe("https://localhost:5173/app/");
    expect(() => resolveZFrontendOrigin("file:///tmp/index.html"))
      .toThrow(/must use http or https/);
  });

});

describe("renderZConfiguredWebView", () => {
  it("emits bootstrap, origin, and ordered injections as typed Z values", () => {
    const output = renderZConfiguredWebView(
      'globalThis.message = "ready";\n',
      "zapp://app/",
      [{
        profile: "base",
        phase: 1,
        sourcePath: "src/preload.ts",
        source: 'globalThis.preloaded = "yes";',
      }],
      [{
        name: "default",
        allowsSelf: true,
        origins: ["https://docs.example.com"],
        externalSchemes: ["https:", "mailto:"],
      }],
    );
    expect(output).toContain('return "zapp://app/";');
    expect(output).toContain("configuredFrontendIsDevelopment");
    expect(output).toContain("return false;");
    expect(output).toContain('return "globalThis.message = \\"ready\\";\\n";');
    expect(output).toContain('profile: "base"');
    expect(output).toContain('source: "globalThis.preloaded = \\"yes\\";"');
    expect(output).toContain("phase: 1");
    expect(output).toContain("Option<ConfiguredWebViewInjection>");
    expect(output).toContain("configuredNavigationProfileExists");
    expect(output).toContain('profile == "default"');
    expect(output).toContain('Option.some("https://docs.example.com")');
    expect(output).toContain('Option.some("mailto:")');
    expect(output).toContain("configuredNavigationExternalSchemeAtIndex");
  });
});

describe("resolveZNativeHost", () => {
  it("selects the visible desktop host by default", () => {
    expect(resolveZNativeHost(undefined)).toBe("desktop");
  });

  it("allows the strict C bridge regression host", () => {
    expect(resolveZNativeHost("bridge")).toBe("bridge");
  });

  it("rejects unknown host modes", () => {
    expect(() => resolveZNativeHost("other"))
      .toThrow(/ZAPP_Z_HOST must be "desktop" or "bridge"/);
  });
});

describe("Z native host inputs", () => {
  it("stages the Z-owned Objective-C registration surface for desktop", () => {
    const files = zNativeStageFiles("desktop");
    expect(files.map((file) => file.destination)).not.toContain("desktop.m");
    expect(files).toContainEqual({
      source: "framework/platform/macos/desktop-smoke.m",
      destination: "desktop-smoke.m",
    });
    expect(files).toContainEqual({
      source: "framework/platform/macos/desktop-smoke.h",
      destination: "desktop-smoke.h",
    });
    expect(files).toContainEqual({
      source: "framework/platform/macos/desktop-smoke.h.zd",
      destination: "desktop-smoke.h.zd",
    });
    expect(files.map((file) => file.destination)).not.toContain("host.c");
    expect(zNativeEntry("desktop")).toBe("main.zs");
    expect(JSON.parse(renderZNativeManifest("desktop", "/app/main.zs", "/native")))
      .toMatchObject({
        target: {
          entry: "/app/main.zs",
          minimumVersion: "14.0",
          includeDirectories: ["/native"],
          link: {
            directories: ["/native"],
            libraries: ["compression"],
          },
        },
      });
    expect(JSON.parse(renderZNativeManifest(
      "desktop",
      "/app/main.zs",
      "/native",
      undefined,
      {},
      false,
      "13.5",
    ))).toMatchObject({
      target: { minimumVersion: "13.5" },
    });
    expect(JSON.parse(renderZNativeManifest(
      "desktop",
      "/app/main.zs",
      "/native",
      "/workspace/native/z",
    ))).toMatchObject({
      dependencies: {
        zapp: { path: "/workspace/native/z" },
      },
    });
    expect(JSON.parse(renderZNativeManifest(
      "desktop",
      "/app/main.zs",
      "/native",
      "/workspace/native/z",
      {
        includeDirectories: ["/vendor/include"],
        directories: ["/vendor/lib"],
        libraries: ["sqlite3", "compression"],
        frameworks: ["Security"],
      },
    ))).toMatchObject({
      target: {
        includeDirectories: ["/native", "/vendor/include"],
        link: {
          directories: ["/native", "/vendor/lib"],
          libraries: ["compression", "sqlite3"],
          frameworks: ["Security"],
        },
      },
    });
    expect(JSON.parse(renderZNativeManifest(
      "desktop",
      "/app/main.zs",
      "/native",
      "/workspace/native/z",
      {},
      true,
    ))).toMatchObject({
      target: {
        link: {
          libraries: ["zapp_desktop_smoke", "compression"],
        },
      },
    });
  });

  it("keeps the strict C bridge on the minimal manifest", () => {
    const files = zNativeStageFiles("bridge");
    expect(files).toContainEqual({
      source: "testing/bridge-host.c",
      destination: "host.c",
    });
    expect(files.map((file) => file.destination)).not.toContain("desktop.m");
    expect(zNativeEntry("bridge")).toBe("embedded.zs");
    expect(JSON.parse(renderZNativeManifest("bridge", "/app/embedded.zs", "/native")))
      .toMatchObject({
        target: {
          kind: "static-library",
          entry: "/app/embedded.zs",
          includeDirectories: ["/native"],
          runtime: { initialize: "initializeApplication" },
        },
      });
  });

  it("keeps the WebKit UI graph, handler, validation, and registration in Z", () => {
    const macOSModulePaths = [
      "application-host.zs",
      "application-runtime.zs",
      "application.zs",
      "configured-smoke.zs",
      "configured-webview.zs",
      "message-handler.zs",
      "message-routing.zs",
      "navigation.zs",
      "response-delivery.zs",
      "runtime.zs",
      "scheme-handler.zs",
      "shell-backend.zs",
      "webview-injections.zs",
      "window-backend.zs",
      "window-construction.zs",
      "window-delegate.zs",
      "window-geometry.zs",
      "window-runtime.zs",
    ];
    const macOSModules = macOSModulePaths.map((module) => readFileSync(
      new URL(`../../native/z/framework/platform/macos/${module}`, import.meta.url),
      "utf8",
    ));
    const macOSPlatform = macOSModules.join("\n");
    const messageHandler = macOSModules[5];
    const objectiveCSmoke = readFileSync(
      new URL("../../native/z/framework/platform/macos/desktop-smoke.m", import.meta.url),
      "utf8",
    );
    const notesFrontend = readFileSync(
      new URL("../../spikes/z-notes/frontend/app.js", import.meta.url),
      "utf8",
    );
    const notesHTML = readFileSync(
      new URL("../../spikes/z-notes/frontend/index.html", import.meta.url),
      "utf8",
    );
    const windowBridge = readFileSync(
      new URL("../../native/z/framework/window-bridge.zs", import.meta.url),
      "utf8",
    );
    const nativeBuilder = readFileSync(
      new URL("./native-z.ts", import.meta.url),
      "utf8",
    );
    const cli = readFileSync(
      new URL("./zapp-cli.ts", import.meta.url),
      "utf8",
    );

    expect(macOSModules).toHaveLength(18);
    expect(macOSModules.every((module) => module.split("\n").length < 700)).toBe(true);
    expect(macOSPlatform).toContain("implements WebKit.WKScriptMessageHandler");
    expect(messageHandler).toContain("if (!frame.mainFrame)");
    expect(messageHandler).toContain("hasConfiguredFrontendOrigin(in sourceURL)");
    expect(messageHandler.indexOf("if (!frame.mainFrame)")).toBeLessThan(
      messageHandler.indexOf("const body = message.body"),
    );
    expect(messageHandler.indexOf("hasConfiguredFrontendOrigin(in sourceURL)")).toBeLessThan(
      messageHandler.indexOf("const body = message.body"),
    );
    expect(macOSPlatform).toContain("body instanceof WebKit.NSString");
    expect(macOSPlatform).toContain("const text: String = body");
    expect(macOSPlatform).toContain("objc.register({");
    expect(macOSPlatform).toContain("window: WebKit.NSWindow");
    expect(macOSPlatform).toContain("webView: WebKit.WKWebView");
    expect(macOSPlatform).toContain("configuration.userContentController = contentController");
    expect(macOSPlatform).toContain(
      "schemeHandler: objc.Adapter<WebKit.WKURLSchemeHandler>",
    );
    expect(macOSPlatform).toContain("implements WebKit.WKURLSchemeHandler");
    expect(macOSPlatform).toContain("objc.adapt<WebKit.WKURLSchemeHandler>(controller)");
    expect(macOSPlatform).toContain("configuration.setURLSchemeHandler(schemeHandler");
    expect(macOSPlatform).toContain("function embeddedAssetIndex(");
    expect(macOSPlatform).toContain("function assetMimeType(");
    expect(macOSPlatform).toContain("function assetPathEscapes(");
    expect(macOSPlatform).toContain("Foundation.NSURLResponse.alloc().initWithURL(");
    expect(macOSPlatform).toContain("task.didReceiveResponse(response)");
    expect(macOSPlatform).toContain("task.didReceiveData(data)");
    expect(macOSPlatform).toContain("task.didFinish()");
    expect(macOSPlatform).toContain("window.contentView = webView");
    expect(macOSPlatform).toContain("startConfiguredWindowSmokeSupport(");
    expect(macOSPlatform).toContain("observeConfiguredWebViewResponse(");
    expect(macOSPlatform).toContain("retiredNativeWindows: Array<MacOSWindowRuntime>");
    expect(macOSPlatform).toContain("recordClosedNativeWindow");
    expect(macOSPlatform).toContain("stopMacOSRunLoop()");
    expect(macOSPlatform).toContain("application.stop(null)");
    expect(macOSPlatform).toContain("AppKit.NSEvent.otherEventWithType(");
    expect(macOSPlatform).toContain("function webViewInjectionProfileExists(");
    expect(macOSPlatform).toContain("function installWebViewScripts(");
    expect(macOSPlatform).toContain("configuredWebViewInjectionCount()");
    expect(macOSPlatform).toContain("configuredWebViewInjectionAtIndex(index)");
    expect(macOSPlatform).toContain("configuredWebViewBootstrap()");
    expect(macOSPlatform).toContain("configuredFrontendOrigin()");
    expect(macOSPlatform).toContain("configuredFrontendIsDevelopment()");
    expect(macOSPlatform).toContain("JsonValue.string(move source)");
    expect(macOSPlatform).toContain("WebKit.WKUserScript.alloc().initWithSource(");
    expect(macOSPlatform).toContain("contentController.addUserScript(script)");
    expect(macOSPlatform).toContain("implements WebKit.WKNavigationDelegate");
    expect(macOSPlatform).toContain("objc.adapt<WebKit.WKNavigationDelegate>(delegate)");
    expect(macOSPlatform).toContain("function resolveLogicalURL(");
    expect(macOSPlatform).toContain("function profileAllowsURL(");
    expect(macOSPlatform).toContain("configuredNavigationOriginAtIndex(");
    expect(macOSPlatform).toContain("navigationProfileAllowsExternalURL(");
    expect(macOSPlatform).toContain("AppKit.NSWorkspace.sharedWorkspace.openURL(url)");
    expect(macOSPlatform).toContain("unknown window navigation profile");
    expect(macOSPlatform).toContain("windows.navigationRequestedNative(");
    expect(macOSPlatform).toContain("deliverWebViewWindowNavigationRequested(");
    expect(macOSPlatform).toContain("allowedByProfile && acceptedByNative");
    expect(macOSPlatform).toContain("decisionHandler(WebKit.WKNavigationActionPolicyAllow)");
    expect(macOSPlatform).toContain("webView.navigationDelegate = navigationDelegate");
    expect(macOSPlatform).toContain("implements WebKit.NSWindowDelegate");
    expect(macOSPlatform).toContain("in notification: WebKit.NSNotification");
    expect(macOSPlatform).toContain("objc.adapt<WebKit.NSWindowDelegate>(delegate)");
    expect(macOSPlatform).toContain("window.delegate = windowDelegate");
    expect(macOSPlatform).toContain("function javascriptJSON(");
    expect(macOSPlatform).toContain("json.encode(in envelope)");
    expect(macOSPlatform).toContain("deliverWebViewWindowEvent(");
    expect(macOSPlatform).toContain("deliverWebViewWindowResize(");
    expect(macOSPlatform).toContain("b.dispatchWindowEvent(");
    expect(macOSPlatform).toContain("webView.evaluateJavaScript(");
    expect(macOSPlatform).toContain("completionHandler: move (value, error): void =>");
    expect(notesFrontend).toContain("windowHandle.subscribe(WindowEvent.FOCUS");
    expect(notesFrontend).toContain("windowHandle.subscribe(WindowEvent.BLUR");
    expect(notesFrontend).toContain("windowHandle.subscribe(WindowEvent.RESIZE");
    expect(notesFrontend).toContain(
      "windowHandle.subscribe(WindowEvent.NAVIGATION_REQUESTED",
    );
    expect(notesHTML).toContain('id="window-events"');
    expect(macOSPlatform).toContain("webView.loadRequest(request)");
    expect(macOSPlatform).toContain("authorizeServiceInvocation(");
    expect(macOSPlatform).toContain("current.capabilitiesForWindow(windowId)");
    expect(macOSPlatform).toContain("unknown window capability profile");
    expect(macOSPlatform).toContain("WindowMessageRoute.handled");
    expect(windowBridge).toContain("export enum WindowBridgeRoute");
    expect(windowBridge).toContain('message.method == "show"');
    expect(windowBridge).toContain('message.method == "hide"');
    expect(windowBridge).toContain('message.method == "close"');
    expect(windowBridge).toContain('message.method == "setTitle"');
    expect(windowBridge).toContain('fields.has("navigation")');
    expect(windowBridge).toContain("copy options.navigation");
    expect(windowBridge).toContain("navigation: move inheritedNavigation");
    expect(macOSPlatform).toContain("window.releasedWhenClosed = false");
    expect(macOSPlatform).toContain("u32(math.trunc(value))");
    expect(macOSPlatform).toContain("WebKit.NSMakeRect(");
    expect(macOSPlatform).toContain("configuredEmbeddedAssetAtIndex(index)");
    expect(macOSPlatform).toContain("Foundation.NSData.borrow(asset.bytes)");
    expect(macOSPlatform).toContain("function decodeBrotliData(");
    expect(macOSPlatform).toContain("raw objc {");
    expect(macOSPlatform).toContain("compression_decode_buffer");
    expect(macOSPlatform).toContain("Foundation.NSError.errorWithDomain(");
    expect(macOSPlatform).toContain("Foundation.NSLocalizedDescriptionKey");
    expect(objectiveCSmoke).toContain("forMainFrameOnly:YES");
    expect(notesFrontend).toContain('from "zapp:services"');
    expect(cli).toContain('if (selectedNativeLanguage !== "z") {');
    expect(cli).toContain("The replacement Z core owns its worker catalog and ZJS link graph");
    expect(cli).toContain('const buildFile = selectedNativeLanguage === "z"');
    expect(notesFrontend).toContain("notes.create");
    expect(notesFrontend).toContain("notes.isEmpty()");
    expect(notesFrontend).toContain("windowHandle.setTitle(");
    expect(notesFrontend).toContain("windowHandle.hide()");
    expect(notesFrontend).toContain("windowHandle.show()");
    expect(notesFrontend).toContain("windowHandle.close()");
    expect(notesHTML).toContain('id="rename-window"');
    expect(notesHTML).toContain('id="hide-window"');
    expect(notesHTML).toContain('id="close-window"');
    expect(notesFrontend).toContain("new AbortController()");
    expect(notesFrontend).toContain("notes.count({ signal: controller.signal })");
    expect(notesFrontend).toContain('error?.name !== "AbortError"');
    expect(notesFrontend).toContain('dataset.cancellation = "ok"');
    expect(notesFrontend).toContain('dataset.hmr = import.meta.hot ? "ready" : "packaged"');
    expect(notesFrontend).toContain("document.body.dataset.inject");
    expect(notesHTML).toContain('<script type="module" src="/app.js"></script>');
    expect(objectiveCSmoke).toContain("zapp_desktop_smoke_observe_response(");
    expect(objectiveCSmoke).toContain("cancelled WebView response ignored");
    expect(objectiveCSmoke).toContain('@"\\\"hmr\\\":\\\"ready\\\""');
    expect(nativeBuilder).toContain(
      'await rm(path.join(stagedAppSource, "z.json"), { force: true });',
    );
    expect(nativeBuilder).toContain('process.env.ZAPP_Z_DESKTOP_SMOKE_SUPPORT === "1"');
    expect(nativeBuilder).toContain('if (desktop && desktopSmokeSupport)');
    expect(nativeBuilder).toContain('libzapp_desktop_smoke.a');
    expect(nativeBuilder).toContain('await rm(desktopArchive, { force: true });');
    expect(nativeBuilder).not.toContain('renderWebviewInjectionsC(injectionEntries)');
    expect(nativeBuilder).not.toContain('renderZWebviewBootstrapC(bootstrapSource)');
    expect(cli).toContain("devUrl,");
    expect(cli).not.toContain("Interactive dev starts with the Phase 1 WebView core");
  });

  it("keeps one stable public Z application identity through main and run", () => {
    const app = readFileSync(
      new URL("../../spikes/z-notes/zapp/main.zs", import.meta.url),
      "utf8",
    );
    const application = readFileSync(
      new URL("../../native/z/api/zapp.zs", import.meta.url),
      "utf8",
    );
    const contract = readFileSync(
      new URL("../../native/z/framework/application-contract.zs", import.meta.url),
      "utf8",
    );
    const publication = readFileSync(
      new URL(
        "../../native/z/framework/application-publication.zs",
        import.meta.url,
      ),
      "utf8",
    );
    const applicationEvents = readFileSync(
      new URL("../../native/z/framework/application-events.zs", import.meta.url),
      "utf8",
    );
    const platform = readFileSync(
      new URL("../../native/z/framework/platform.zs", import.meta.url),
      "utf8",
    );
    const headless = readFileSync(
      new URL("../../native/z/framework/platform/headless.zs", import.meta.url),
      "utf8",
    );
    const headlessSmoke = readFileSync(
      new URL("../../native/z/tests/application-platform-smoke.zs", import.meta.url),
      "utf8",
    );
    const lifecycleContract = readFileSync(
      new URL("../../native/z/api/zapp/service.zs", import.meta.url),
      "utf8",
    );
    const lifecycles = readFileSync(
      new URL("../../native/z/framework/service-lifecycle.zs", import.meta.url),
      "utf8",
    );
    const windows = readFileSync(
      new URL("../../native/z/framework/window.zs", import.meta.url),
      "utf8",
    );
    const dialogs = readFileSync(
      new URL("../../native/z/framework/dialog.zs", import.meta.url),
      "utf8",
    );
    const shell = readFileSync(
      new URL("../../native/z/framework/shell.zs", import.meta.url),
      "utf8",
    );
    const shellBridge = readFileSync(
      new URL("../../native/z/framework/shell-bridge.zs", import.meta.url),
      "utf8",
    );
    const macOSDialogs = readFileSync(
      new URL(
        "../../native/z/framework/platform/macos/dialog-backend.zs",
        import.meta.url,
      ),
      "utf8",
    );
    const applicationServices = readFileSync(
      new URL("../../native/z/framework/application-services.zs", import.meta.url),
      "utf8",
    );
    const workerEngine = readFileSync(
      new URL("../../native/z/framework/worker/engine.zs", import.meta.url),
      "utf8",
    );
    const applicationWorkers = readFileSync(
      new URL(
        "../../native/z/framework/worker/application-workers.zs",
        import.meta.url,
      ),
      "utf8",
    );
    const workerManager = readFileSync(
      new URL(
        "../../native/z/framework/worker/worker-manager.zs",
        import.meta.url,
      ),
      "utf8",
    );
    const workerEvents = readFileSync(
      new URL(
        "../../native/z/framework/worker/events.zs",
        import.meta.url,
      ),
      "utf8",
    );
    const workerManagerRuntime = readFileSync(
      new URL(
        "../../native/z/framework/worker/manager-runtime.zs",
        import.meta.url,
      ),
      "utf8",
    );
    const workerRuntimeHeader = readFileSync(
      new URL(
        "../../native/z/framework/worker/zapp_worker_runtime.h",
        import.meta.url,
      ),
      "utf8",
    );
    const zjsWorkerRuntime = readFileSync(
      new URL(
        "../../native/z/framework/worker/zjs/zapp_worker_zjs.m",
        import.meta.url,
      ),
      "utf8",
    );
    const macOSApplication = readFileSync(
      new URL(
        "../../native/z/framework/platform/macos/application.zs",
        import.meta.url,
      ),
      "utf8",
    );
    const macOSApplicationHost = readFileSync(
      new URL(
        "../../native/z/framework/platform/macos/application-host.zs",
        import.meta.url,
      ),
      "utf8",
    );
    const workerSpike = readFileSync(
      new URL("../../native/z/smokes/zjs-worker-host/main.zs", import.meta.url),
      "utf8",
    );

    expect(app).toContain("const app = new Application();");
    expect(app).not.toContain("function createApplication(): Application on thread.main");
    expect(application).toContain("readonly metadata: ApplicationMetadata;");
    expect(application).toContain("readonly context: ApplicationContext;");
    expect(application).toContain("const metadata = configuredApplicationMetadata();");
    expect(application).toContain("this.context = createApplicationContext(in metadata);");
    expect(application).toContain("this.metadata = move metadata;");
    expect(app).toContain("const notesService = createNotesService();");
    expect(app).toContain("const notesRegistered = attempt app.services.register(");
    expect(app).toContain("const healthRegistered = attempt app.services.register(");
    expect(app).toContain('inject: Array<String>("base")');
    expect(app).toContain("const result = attempt await app.run();");
    expect(application).toContain("export readonly class Application");
    expect(application).toContain("constructor()");
    expect(application).toContain("static function current(): Application");
    expect(application).toContain("const currentApplication = Once<Application>();");
    expect(application).toContain("const publicationState = currentApplication.state();");
    expect(application).toContain(
      "try requireApplicationPublicationState(publicationState);",
    );
    expect(publication).toContain("state: ApplicationState.running");
    expect(publication).toContain("Another Application.run() is already active");
    expect(publication).toContain("state: ApplicationState.stopped");
    expect(publication).toContain("cannot publish a new application after process shutdown");
    expect(application).toContain("function state(): ApplicationState on thread.main");
    expect(application).toContain("readonly events: ApplicationEvents;");
    expect(application).toContain("function quit(): void on thread.main");
    expect(applicationEvents).toContain(
      "export readonly class ApplicationQuitRequestedEvent on thread.main",
    );
    expect(applicationEvents).toContain(
      "readonly quitRequested: Event<ApplicationQuitRequestedEvent>;",
    );
    expect(applicationEvents).toContain("function cancel(): void");
    expect(applicationEvents).toContain("internal function approveQuit(): boolean");
    expect(application).toContain(
      "this.windows = createWindowManager();",
    );
    expect(application).toContain("this.dialogs = createDialogManager();");
    expect(application).toContain("this.shell = createShellManager();");
    expect(application).toContain(
      "this.workers = createWorkerManager(configuredApplicationWorkers());",
    );
    expect(application).toContain(
      "readonly capabilities: ApplicationCapabilities",
    );
    expect(application).toContain("this.services = createApplicationServices();");
    expect(application).toContain("throws ApplicationError on thread.main");
    expect(application).toContain("const sourceApplication = this;");
    expect(application).toContain("const config = prepareApplication(in sourceApplication);");
    expect(application).toContain("const lifetime = currentApplication.initialize(move publishedApplication);");
    expect(application).toContain("runState: applicationState,");
    expect(application).toContain("const updates = new TaskScope();");
    expect(application).toContain("const { routes, asynchronous, lifecycles }");
    expect(application).toContain("synchronous: routes");
    expect(application).toContain("lifecycles,");
    expect(contract).toContain("export readonly class PreparedApplication on thread.main");
    expect(contract).toContain("readonly context: ApplicationContext");
    expect(contract).toContain("readonly capabilities: ApplicationCapabilities");
    expect(contract).toContain("readonly events: ApplicationEvents");
    expect(contract).toContain("readonly dialogs: DialogManager");
    expect(contract).toContain("readonly shell: ShellManager");
    expect(shell).toContain("export readonly class ShellManager on thread.main");
    expect(shell).toContain("function openExternal(");
    expect(shellBridge).toContain('message.method != "__zapp:shell:open-external"');
    expect(shellBridge).toContain("if (!permissions.shellOpen)");
    expect(shellBridge).toContain('allowsPermission("shell:open")');
    expect(shellBridge).toContain("if (!policy(in navigationProfile, in input.url))");
    expect(platform).toContain("export async function runApplicationPlatform(");
    expect(platform).toContain('from "./platform/macos/application.zs"');
    expect(platform).toContain("return try await runMacOSApplication(move config, updates);");
    expect(macOSApplication).toContain("events.start(quitApplication);");
    expect(macOSApplicationHost).toContain("implements AppKit.NSApplicationDelegate");
    expect(macOSApplicationHost).toContain('as "applicationShouldTerminate:"');
    expect(headless).toContain("class HeadlessApplicationRuntime");
    expect(headless).toContain("export async function runApplicationPlatform(");
    expect(headlessSmoke).toContain("attempt await runHeadlessApplicationPlatform(");
    expect(lifecycleContract).toContain("export trait ServiceLifecycle");
    expect(lifecycleContract).toContain("throws ServiceLifecycleError on thread.main");
    expect(lifecycles).toContain("export type ServiceLifecycleHook");
    expect(lifecycles).toContain("function register<T: ServiceLifecycle>(");
    expect(lifecycles).toContain("invokeServiceLifecycle(in service, phase, in context)");
    expect(lifecycles).toContain("function start(");
    expect(lifecycles).toContain("function stop(");
    expect(lifecycles).toContain("while (rollback > 0)");
    expect(lifecycles).toContain("while (remaining > 0)");
    expect(windows).toContain("internal constructor(");
    expect(windows).toContain("internal readonly manager: Weak<WindowManager>");
    expect(windows).toContain("internal readonly state: WindowManagerState");
    expect(windows).toContain(
      'capabilities: Array<String> = Array<String>("default")',
    );
    expect(windows).not.toMatch(/\b__[A-Za-z]/);
    expect(dialogs).toContain("export readonly class DialogManager on thread.main");
    expect(dialogs).toContain("async function openFile(");
    expect(dialogs).toContain("async function openFiles(");
    expect(dialogs).toContain("async function openDirectory(");
    expect(dialogs).toContain("async function saveFile(");
    expect(dialogs).toContain("Option<String> throws DialogError on thread.main");
    expect(dialogs).toContain("Option<Array<String>> throws DialogError on thread.main");
    expect(macOSDialogs).toContain("AppKit.NSOpenPanel.openPanel()");
    expect(macOSDialogs).toContain("AppKit.NSSavePanel.savePanel()");
    expect(macOSDialogs).toContain("panel.allowedContentTypes = contentTypes");
    expect(applicationServices).toContain("internal struct ConfiguredServices");
    expect(applicationServices).toContain("export readonly class ApplicationServices on thread.main");
    expect(applicationServices).toContain("internal function prepare(inout this): ConfiguredServices");
    expect(applicationServices).toContain("export readonly struct ServiceRegistrationError");
    expect(applicationServices).toContain("if (this.prepared)");
    expect(applicationServices).toContain("routes: this.routes.take()");
    expect(applicationServices).toContain(
      "asynchronous: this.asynchronous.take()",
    );
    expect(applicationServices).toContain(
      "lifecycles: this.lifecycles.freeze()",
    );
    expect(workerEngine).toContain("export trait WorkerEngine<Command>");
    expect(workerEngine).toContain("export readonly class WorkerMailbox<Command>");
    expect(workerEngine).toContain("export struct WorkerInbox<Command>");
    expect(workerEngine).toContain("Engine: WorkerEngine<Command>");
    expect(applicationWorkers).toContain(
      "export readonly class ApplicationWorkers",
    );
    expect(applicationWorkers).toContain(
      "readonly controls: readonly Array<ApplicationWorkerControl>",
    );
    expect(applicationWorkers).toContain("readonly identity: usize");
    expect(applicationWorkers).toContain("function requestCancellation(): void");
    expect(applicationWorkers).toContain("native.zapp_worker_runtime_join(this.identity)");
    expect(applicationWorkers).toContain("deinit {");
    expect(applicationWorkers).toContain("native.zapp_worker_runtime_destroy(this.identity)");
    expect(applicationWorkers).toContain(
      "internal readonly class ApplicationWorkerServiceRequest",
    );
    expect(workerManager).toContain("export readonly class WorkerManager on thread.main");
    expect(workerManager).toContain("function get<Command, Message>(");
    expect(workerManager).toContain("function getRaw(in id: String): Option<RawApplicationWorker>");
    expect(workerManager).toContain("function all(): Array<RawApplicationWorker>");
    expect(workerManager).toContain("export readonly class ApplicationWorker<Command, Message>");
    expect(workerManager).toContain("export readonly class RawApplicationWorker");
    expect(workerManager).toContain("function send(");
    expect(workerManager).toContain("function state(): ApplicationWorkerState");
    expect(workerManager).toContain(
      "readonly messages: Event<ApplicationWorkerMessage>",
    );
    expect(workerManager).toContain("internal function publishMessage(");
    expect(workerManager).toContain("ApplicationWorkerSendErrorKind.saturated");
    expect(workerEvents).toContain("readonly all: Event<ApplicationWorkerEvent>");
    expect(workerEvents).toContain("readonly restarting: Event<ApplicationWorkerRestartingEvent>");
    expect(workerManager).toContain("export type ApplicationWorkerEvent = FrameworkApplicationWorkerEvent");
    expect(workerManager).toContain(
      "export type ApplicationWorkerMessage = FrameworkApplicationWorkerMessage",
    );
    expect(workerManager).toContain(
      "export type ApplicationWorkerMessageSubscription =",
    );
    expect(workerManagerRuntime).toContain(
      "workers.publishMessage(in workerId, in channel, in payload)",
    );
    expect(app).toContain("worker.events.all.subscribe(");
    expect(app).toContain("worker.messages.subscribe(");
    expect(app).toContain("worker manager sent ping");
    expect(workerRuntimeHeader).toContain("int32_t (*dispatch)(");
    expect(workerRuntimeHeader).toContain("zapp_worker_runtime_dispatch(");
    expect(zjsWorkerRuntime).toContain("ZAPP_ZJS_WORKER_INBOX_CAPACITY 64");
    expect(zjsWorkerRuntime).toContain("pthread_cond_wait(");
    expect(zjsWorkerRuntime).toContain("pthread_cond_timedwait(");
    expect(zjsWorkerRuntime).toContain("&worker->finished");
    expect(zjsWorkerRuntime).toContain("record_worker_failure(");
    expect(zjsWorkerRuntime).toContain("worker->restart_max_retries");
    expect(zjsWorkerRuntime).toContain("cancel_and_release_all_pending_services(");
    const serviceStart = macOSApplication.indexOf("config.lifecycles.start(in context)");
    const workerStart = macOSApplication.indexOf("startConfiguredApplicationWorkers(");
    const workerCancel = macOSApplication.indexOf("workers.requestCancellation()");
    const workerJoin = macOSApplication.indexOf("workers.join()");
    const serviceStop = macOSApplication.indexOf("config.lifecycles.stop(in context)");
    expect(serviceStart).toBeGreaterThan(-1);
    expect(workerStart).toBeGreaterThan(serviceStart);
    expect(workerCancel).toBeGreaterThan(workerStart);
    expect(workerJoin).toBeGreaterThan(workerCancel);
    expect(serviceStop).toBeGreaterThan(workerJoin);
    expect(workerSpike).toContain(
      'from "../../framework/worker/engine.zs"',
    );
    expect(workerSpike).toContain(
      "struct ZjsWorkerEngine implements WorkerEngine<WorkerCommand>",
    );
  });

  it("freezes value services into an arbitrary-thread callable router", () => {
    const contracts = readFileSync(
      new URL("../../native/z/framework/service-contract.zs", import.meta.url),
      "utf8",
    );
    const services = readFileSync(
      new URL("../../native/z/framework/services.zs", import.meta.url),
      "utf8",
    );
    const notes = readFileSync(
      new URL("../../spikes/z-notes/zapp/notes-service.zs", import.meta.url),
      "utf8",
    );
    const notesCore = readFileSync(
      new URL("../../spikes/z-notes/zapp/notes-core.zs", import.meta.url),
      "utf8",
    );
    const health = readFileSync(
      new URL("../../spikes/z-notes/zapp/health-service.zs", import.meta.url),
      "utf8",
    );
    const syncNotes = readFileSync(
      new URL("../../spikes/z-notes/zapp/sync-notes-service.zs", import.meta.url),
      "utf8",
    );

    expect(contracts).toContain("=> ServiceOutcome on thread.any");
    expect(services).toContain("function freeze(move this): Services");
    expect(services).toContain("function register<T: Service>(");
    expect(services).toContain("const handler = serviceHandler(service);");
    expect(services).toContain("service.invoke(in invocation)");
    expect(services).not.toContain("ServiceBinding");
    expect(services).toContain("readonly Map<String, ServiceHandler>");
    expect(notes).toContain("export readonly class NotesService implements ServiceLifecycle");
    expect(notes).toContain("readonly core: NotesCore");
    expect(notes).toContain("function count(): u64 on thread.main");
    expect(notes).toContain("await delay(1)");
    expect(notes).not.toContain("function invoke(");
    expect(notes).not.toContain("AsyncService");
    expect(notes).not.toContain("createNotesHandler");
    expect(notes).toContain("function start(");
    expect(notes).toContain("function stop(");
    expect(notes).not.toContain("NotesAdapter");
    expect(notesCore).toContain("readonly state: Mutex<NotesState>");
    expect(notesCore).toContain("export function invokeNotesCore(");
    expect(syncNotes).toContain("export readonly class SyncNotesService implements Service");
    expect(syncNotes).toContain("invokeNotesCore(in core, in invocation)");
    expect(health).toContain("export struct HealthService");
    expect(health).toContain('return "ready";');
  });

  it("keeps async services separate from the synchronous fast path", () => {
    const contracts = readFileSync(
      new URL("../../native/z/framework/async-service-contract.zs", import.meta.url),
      "utf8",
    );
    const services = readFileSync(
      new URL("../../native/z/framework/async-services.zs", import.meta.url),
      "utf8",
    );
    const bridge = readFileSync(
      new URL("../../native/z/framework/async-bridge.zs", import.meta.url),
      "utf8",
    );
    const synchronousServices = readFileSync(
      new URL("../../native/z/framework/services.zs", import.meta.url),
      "utf8",
    );
    const applicationServices = readFileSync(
      new URL("../../native/z/framework/application-services.zs", import.meta.url),
      "utf8",
    );
    const synchronousBridge = readFileSync(
      new URL("../../native/z/framework/bridge.zs", import.meta.url),
      "utf8",
    );
    const smoke = readFileSync(
      new URL("../../native/z/smokes/async-service/main.zs", import.meta.url),
      "utf8",
    );

    expect(contracts).toContain("export type AsyncServiceHandler");
    expect(contracts).toContain("async (in invocation: ServiceInvocation) => ServiceOutcome on thread.any");
    expect(contracts).toContain("export trait AsyncService");
    expect(services).toContain("function registerAsync<T: AsyncService>(");
    expect(services).toContain("readonly Map<String, AsyncServiceHandler>");
    expect(services).toContain("readonly synchronous: Services");
    expect(services).toContain("async function invoke(");
    expect(bridge).toContain("export async function routeMessageWithServicesAsync(");
    expect(synchronousServices).not.toContain("async function");
    expect(synchronousServices).not.toContain("AsyncService");
    expect(synchronousBridge).not.toContain("async function");
    expect(applicationServices).toContain("function register<T>(");
    expect(applicationServices).toContain("internal function registerGeneratedAsync<T: AsyncService>(");
    expect(applicationServices).toContain("internal function registerGeneratedAsyncWithLifecycle<");
    expect(smoke).toContain("await scheduler.yield()");
    expect(smoke).toContain('builder.registerAsync(');
    expect(smoke).toContain("async function validateRoutes(services: AsyncServices): i32");
    expect(smoke.match(/await routeMessageWithServicesAsync\(/g)).toHaveLength(3);
    expect(smoke).toContain("await routeMessageWithServicesAsync(");
    expect(smoke).toContain("await delay(1000)");
    expect(smoke).toContain("requests.cancel(50)");
    expect(smoke).toContain("resumedAfterCancellation");
  });
});

describe("parseZCompilerIdentity", () => {
  it("decodes the pinned compiler contract", () => {
    expect(parseZCompilerIdentity("z 0.1.0-dev revision 2026-08-31.1 compiler-api 2\n"))
      .toEqual({
        languageVersion: "0.1.0-dev",
        compilerRevision: "2026-08-31.1",
        compilerApi: 2,
      });
  });

  it("rejects an unversioned compiler", () => {
    expect(() => parseZCompilerIdentity("unknown z compiler command version\n"))
      .toThrow(/requires a compiler that supports `z version`/);
  });
});

describe("validateZCompilerIdentity", () => {
  const expected = {
    languageVersion: "0.1.0-dev",
    compilerRevision: "2026-08-31.1",
    compilerApi: 2,
  };

  it("accepts the exact pinned identity", () => {
    expect(() => validateZCompilerIdentity(expected, expected, "compiler-contract.json"))
      .not.toThrow();
  });

  it("reports every incompatible compiler dimension", () => {
    expect(() => validateZCompilerIdentity(expected, {
      languageVersion: "0.2.0-dev",
      compilerRevision: "later",
      compilerApi: 3,
    }, "compiler-contract.json")).toThrow(
      /language 0\.2\.0-dev.*revision later.*compiler API 3.*compiler-contract\.json/,
    );
  });
});
