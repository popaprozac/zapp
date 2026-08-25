import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import {
  parseZCompilerIdentity,
  renderZWebviewBootstrapC,
  renderZNativeManifest,
  resolveZNativeHost,
  validateZCompilerIdentity,
  zNativeEntry,
  zNativeStageFiles,
} from "./native-z";

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
            frameworks: ["AppKit", "WebKit", "CoreFoundation"],
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
    const macOSPlatform = readFileSync(
      new URL("../../native/z/framework/platform/macos.zs", import.meta.url),
      "utf8",
    );
    const objectiveCHost = readFileSync(
      new URL("../../native/z/framework/platform/macos/desktop.m", import.meta.url),
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
    expect(objectiveCHost).not.toContain(
      "ZAppDesktopHost : NSObject <WKScriptMessageHandler",
    );
    expect(objectiveCHost).toContain("@property(nonatomic, weak) NSWindow *window");
    expect(objectiveCHost).toContain("@property(nonatomic, weak) WKWebView *webView");
    expect(objectiveCHost).not.toContain("[[WKWebView alloc]");
    expect(objectiveCHost).not.toContain("[[NSWindow alloc]");
    expect(objectiveCHost).not.toContain("addScriptMessageHandler:self");
    expect(objectiveCHost).not.toContain("[body isKindOfClass:[NSString class]]");
    expect(objectiveCHost).not.toContain("routeScriptMessage:");
    expect(objectiveCHost).not.toContain("int main(");
    expect(objectiveCHost).toContain("services.notes.create");
  });

  it("gives the public Z builder ownership of main and run", () => {
    const app = readFileSync(
      new URL("../../spikes/z-notes/zapp/main.zs", import.meta.url),
      "utf8",
    );
    const application = readFileSync(
      new URL("../../native/z/framework/application.zs", import.meta.url),
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
      new URL("../../native/z/framework/service-lifecycle-contract.zs", import.meta.url),
      "utf8",
    );
    const lifecycles = readFileSync(
      new URL("../../native/z/framework/service-lifecycle.zs", import.meta.url),
      "utf8",
    );

    expect(app).toContain('let app = Application({ name: "Notes" });');
    expect(app).toContain('app.services.registerWithLifecycle("notes", createNotesService());');
    expect(app).toContain("const result = attempt app.run();");
    expect(application).toContain("export struct Application");
    expect(application).toContain("services: ApplicationServicesBuilder = createApplicationServices();");
    expect(application).toContain("throws ServiceLifecycleError on thread.main");
    expect(application).toContain("const { routes, lifecycles } = services.freezeConfigured();");
    expect(application).toContain("services: routes");
    expect(application).toContain("lifecycles,");
    expect(contract).toContain("export struct ApplicationConfig");
    expect(platform).toContain("export function runApplicationPlatform(");
    expect(platform).toContain("return try runMacOSApplication(move config);");
    expect(headless).toContain("struct HeadlessApplicationRuntime");
    expect(headless).toContain("export function runApplicationPlatform(");
    expect(headlessSmoke).toContain("runHeadlessApplicationPlatform(move config)");
    expect(lifecycleContract).toContain("export trait ServiceLifecycle");
    expect(lifecycleContract).toContain("export type ServiceLifecycleHook");
    expect(lifecycleContract).toContain("throws ServiceLifecycleError on thread.main");
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

    expect(contracts).toContain("=> ServiceOutcome on thread.any");
    expect(services).toContain("function freeze(move this): Services");
    expect(services).toContain("function register<T: Service>(");
    expect(services).toContain("const handler = serviceHandler(service);");
    expect(services).toContain("service.invoke(in invocation)");
    expect(services).not.toContain("ServiceBinding");
    expect(services).toContain("readonly Map<String, ServiceHandler>");
    expect(notes).toContain("export readonly class NotesService implements Service, ServiceLifecycle");
    expect(notes).toContain("readonly state: Mutex<NotesState>");
    expect(notes).toContain("function invoke(in invocation: ServiceInvocation): ServiceOutcome");
    expect(notes).not.toContain("createNotesHandler");
    expect(notes).toContain("function start(");
    expect(notes).toContain("function stop(");
    expect(notes).not.toContain("NotesAdapter");
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
    expect(services).toContain("export trait AsyncService");
    expect(services).toContain("function registerAsync<T: AsyncService>(");
    expect(services).toContain("readonly Map<String, AsyncServiceHandler>");
    expect(services).toContain("readonly synchronous: Services");
    expect(services).toContain("async function invoke(");
    expect(bridge).toContain("export async function routeMessageWithServicesAsync(");
    expect(synchronousServices).not.toContain("async function");
    expect(synchronousBridge).not.toContain("async function");
    expect(smoke).toContain("await scheduler.yield()");
    expect(smoke).toContain('builder.registerAsync(');
    expect(smoke).toContain("async function validateRoutes(services: AsyncServices): i32");
    expect(smoke.match(/await routeMessageWithServicesAsync\(/g)).toHaveLength(2);
    expect(smoke).toContain("await routeMessageWithServicesAsync(");
  });
});

describe("parseZCompilerIdentity", () => {
  it("decodes the pinned compiler contract", () => {
    expect(parseZCompilerIdentity("z 0.1.0-dev revision 2026-08-23.1 compiler-api 2\n"))
      .toEqual({
        languageVersion: "0.1.0-dev",
        compilerRevision: "2026-08-23.1",
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
    compilerRevision: "2026-08-23.1",
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
