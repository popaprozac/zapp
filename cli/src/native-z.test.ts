import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import {
  parseZCompilerIdentity,
  renderZApplicationMetadata,
  renderZFrontendConfigC,
  renderZWebviewBootstrapConfig,
  renderZWebviewBootstrapC,
  renderZNativeManifest,
  resolveZFrontendOrigin,
  resolveZNativeHost,
  validateZCompilerIdentity,
  zNativeEntry,
  zNativeStageFiles,
} from "./native-z";

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

describe("renderZWebviewBootstrapC", () => {
  it("preserves arbitrary UTF-8 source without C literal ambiguity", () => {
    const source = 'globalThis.message = "héllo\\n世界";\u2028';
    const output = renderZWebviewBootstrapC(source);
    const bytes = Array.from(
      output.matchAll(/\\x([0-9a-f]{2})/g),
      (match) => Number.parseInt(match[1], 16),
    );

    expect(new TextDecoder().decode(Uint8Array.from(bytes))).toBe(source);
    expect(output).toContain("const char *zapp_webview_bootstrap_script(void)");
  });

  it("emits a valid empty C string", () => {
    expect(renderZWebviewBootstrapC(""))
      .toContain('static const char zapp_webview_bootstrap[] =\n  "";');
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

  it("emits the resolved origin without C string escaping ambiguity", () => {
    const output = renderZFrontendConfigC("http://localhost:5173");
    const bytes = Array.from(
      output.matchAll(/0x([0-9a-f]{2})/g),
      (match) => Number.parseInt(match[1], 16),
    );
    expect(new TextDecoder().decode(Uint8Array.from(bytes.slice(0, -1))))
      .toBe("http://localhost:5173/");
    expect(bytes.at(-1)).toBe(0);
    expect(output).toContain("zapp_desktop_frontend_origin");
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
    expect(files).toContainEqual({
      source: "framework/platform/macos/desktop.m",
      destination: "desktop.m",
    });
    expect(files).toContainEqual({
      source: "framework/platform/macos/zapp_desktop.h",
      destination: "zapp_desktop.h",
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
            libraries: ["zapp_desktop_host", "compression"],
          },
        },
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
    const macOSPlatform = readFileSync(
      new URL("../../native/z/framework/platform/macos.zs", import.meta.url),
      "utf8",
    );
    const objectiveCHost = readFileSync(
      new URL("../../native/z/framework/platform/macos/desktop.m", import.meta.url),
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
    const nativeBuilder = readFileSync(
      new URL("./native-z.ts", import.meta.url),
      "utf8",
    );
    const cli = readFileSync(
      new URL("./zapp-cli.ts", import.meta.url),
      "utf8",
    );

    expect(macOSPlatform).toContain("implements native.WKScriptMessageHandler");
    expect(macOSPlatform).toContain("body instanceof native.NSString");
    expect(macOSPlatform).toContain("const text: String = body");
    expect(macOSPlatform).toContain("objc.register({");
    expect(macOSPlatform).toContain("window: native.NSWindow");
    expect(macOSPlatform).toContain("webView: native.WKWebView");
    expect(macOSPlatform).toContain("configuration.userContentController = contentController");
    expect(macOSPlatform).toContain("window.contentView = webView");
    expect(macOSPlatform).toContain("native.ZAppDesktopBridge.attachWindow(");
    expect(macOSPlatform).toContain("native.zapp_desktop_has_injection_profile(profile)");
    expect(macOSPlatform).toContain("native.zapp_desktop_window_select_injection_profile(");
    expect(macOSPlatform).toContain("window.releasedWhenClosed = false");
    expect(objectiveCHost).not.toContain(
      "ZAppDesktopHost : NSObject <WKScriptMessageHandler",
    );
    expect(objectiveCHost).toContain("@property(nonatomic, strong) NSWindow *window");
    expect(objectiveCHost).toContain("@property(nonatomic, strong) WKWebView *webView");
    expect(objectiveCHost).toContain("windowsByNativeId");
    expect(objectiveCHost).not.toContain("[[WKWebView alloc]");
    expect(objectiveCHost).not.toContain("[[NSWindow alloc]");
    expect(objectiveCHost).not.toContain("addScriptMessageHandler:self");
    expect(objectiveCHost).not.toContain("[body isKindOfClass:[NSString class]]");
    expect(objectiveCHost).not.toContain("routeScriptMessage:");
    expect(objectiveCHost).not.toContain("int main(");
    expect(objectiveCHost).toContain("ZAppDesktopAssetSchemeHandler");
    expect(objectiveCHost).toContain("zapp_desktop_resolve_logical_url");
    expect(objectiveCHost).toContain("zapp_desktop_has_frontend_origin");
    expect(objectiveCHost).toContain("zapp_desktop_install_injection_profiles");
    expect(objectiveCHost).toContain("data-zapp-injected-style");
    expect(objectiveCHost).toContain("decidePolicyForNavigationAction:");
    expect(objectiveCHost).toContain("forMainFrameOnly:YES");
    expect(objectiveCHost).toContain("loadRequest:");
    expect(objectiveCHost).not.toContain("loadHTMLString:");
    expect(notesFrontend).toContain("services.notes.create");
    expect(notesFrontend).toContain("services.notes.isEmpty()");
    expect(notesFrontend).toContain("new AbortController()");
    expect(notesFrontend).toContain("services.notes.count({ signal: controller.signal })");
    expect(notesFrontend).toContain('error?.name !== "AbortError"');
    expect(notesFrontend).toContain('dataset.cancellation = "ok"');
    expect(notesFrontend).toContain('dataset.hmr = import.meta.hot ? "ready" : "packaged"');
    expect(notesFrontend).toContain("document.body.dataset.inject");
    expect(notesHTML).toContain('<script type="module" src="/app.js"></script>');
    expect(objectiveCHost).toContain("if (!strongSelf.smokeMode) return;");
    expect(objectiveCHost).toContain("cancelled WebView response ignored");
    expect(objectiveCHost).toContain('@"\\\"hmr\\\":\\\"ready\\\""');
    expect(nativeBuilder).toContain(
      'await rm(path.join(stagedAppSource, "z.json"), { force: true });',
    );
    expect(cli).toContain("devUrl,");
    expect(cli).not.toContain("Interactive dev starts with the Phase 1 WebView core");
  });

  it("gives the public Z builder ownership of main and run", () => {
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

    expect(app).toContain("let app = Application();");
    expect(application).toContain(
      "readonly metadata: ApplicationMetadata = configuredApplicationMetadata()",
    );
    expect(app).toContain('app.services.register("notes", createNotesService());');
    expect(app).toContain('app.services.register("health", createHealthService());');
    expect(app).toContain('inject: Array<String>("base")');
    expect(app).toContain("const result = attempt await app.run();");
    expect(application).toContain("export struct Application");
    expect(application).toContain(
      "readonly windows: WindowManager = createWindowManager()",
    );
    expect(application).toContain("services: ApplicationServicesBuilder = createApplicationServices();");
    expect(application).toContain("throws ApplicationError on thread.main");
    expect(application).toContain("const config = prepareApplication(move this);");
    expect(application).toContain("const updates = new TaskScope();");
    expect(application).toContain("const { routes, asynchronous, lifecycles }");
    expect(application).toContain("synchronous: routes");
    expect(application).toContain("lifecycles,");
    expect(contract).toContain("export readonly class PreparedApplication on thread.main");
    expect(platform).toContain("export async function runApplicationPlatform(");
    expect(platform).toContain("return try await runMacOSApplication(move config, updates);");
    expect(headless).toContain("struct HeadlessApplicationRuntime");
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
    expect(notes).toContain("async function count(): u64 on thread.main");
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
    expect(applicationServices).toContain("function __registerGeneratedAsync<T: AsyncService>(");
    expect(applicationServices).toContain("function __registerGeneratedAsyncWithLifecycle<");
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
    expect(parseZCompilerIdentity("z 0.1.0-dev revision 2026-08-25.1 compiler-api 2\n"))
      .toEqual({
        languageVersion: "0.1.0-dev",
        compilerRevision: "2026-08-25.1",
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
    compilerRevision: "2026-08-25.1",
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
