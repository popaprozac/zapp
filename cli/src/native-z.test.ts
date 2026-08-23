import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import {
  parseZCompilerIdentity,
  renderZWebviewBootstrapC,
  resolveZNativeHost,
  validateZCompilerIdentity,
  zNativeManifest,
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
    expect(zNativeStageFiles("desktop")).toContain("app.zs");
    expect(zNativeStageFiles("desktop")).toContain("application.zs");
    expect(zNativeStageFiles("desktop")).toContain("application-contract.zs");
    expect(zNativeStageFiles("desktop")).toContain("platform.zs");
    expect(zNativeStageFiles("desktop")).toContain("platform/macos.zs");
    expect(zNativeStageFiles("desktop")).toContain("services.zmeta.json");
    expect(zNativeStageFiles("desktop")).toContain("zapp_desktop.h");
    expect(zNativeStageFiles("desktop")).not.toContain("zapp_desktop.h.zd");
    expect(zNativeStageFiles("desktop")).not.toContain("core.zs");
    expect(zNativeStageFiles("desktop")).not.toContain("host.c");
    expect(zNativeManifest("desktop")).toBe("desktop-z.json");
  });

  it("keeps the strict C bridge on the minimal manifest", () => {
    expect(zNativeStageFiles("bridge")).not.toContain("application.zs");
    expect(zNativeStageFiles("bridge")).not.toContain("platform/macos.zs");
    expect(zNativeStageFiles("bridge")).toContain("core.zs");
    expect(zNativeStageFiles("bridge")).not.toContain("zapp_desktop.h");
    expect(zNativeStageFiles("bridge")).not.toContain("desktop.m");
    expect(zNativeManifest("bridge")).toBe("z.json");
  });

  it("keeps the WebKit UI graph, handler, validation, and registration in Z", () => {
    const macOSPlatform = readFileSync(
      new URL("../../native/z/platform/macos.zs", import.meta.url),
      "utf8",
    );
    const objectiveCHost = readFileSync(
      new URL("../../native/z/desktop.m", import.meta.url),
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
      new URL("../../native/z/app.zs", import.meta.url),
      "utf8",
    );
    const application = readFileSync(
      new URL("../../native/z/application.zs", import.meta.url),
      "utf8",
    );
    const contract = readFileSync(
      new URL("../../native/z/application-contract.zs", import.meta.url),
      "utf8",
    );
    const platform = readFileSync(
      new URL("../../native/z/platform.zs", import.meta.url),
      "utf8",
    );
    const headless = readFileSync(
      new URL("../../native/z/platform/headless.zs", import.meta.url),
      "utf8",
    );
    const headlessSmoke = readFileSync(
      new URL("../../native/z/application-platform-smoke.zs", import.meta.url),
      "utf8",
    );

    expect(app).toContain('let app = Application({ name: "Notes" });');
    expect(app).toContain('app.services.register("notes", createNotesService());');
    expect(app).toContain("return app.run();");
    expect(application).toContain("export struct Application");
    expect(application).toContain("services: ServicesBuilder = createServices();");
    expect(application).toContain("function run(move this): i32 on thread.main");
    expect(application).toContain("services: services.freeze()");
    expect(contract).toContain("export struct ApplicationConfig");
    expect(platform).toContain("export function runApplicationPlatform(");
    expect(platform).toContain("return runMacOSApplication(move config);");
    expect(headless).toContain("struct HeadlessApplicationRuntime");
    expect(headless).toContain("export function runApplicationPlatform(");
    expect(headlessSmoke).toContain("runHeadlessApplicationPlatform(move config)");
  });

  it("freezes value services into an arbitrary-thread callable router", () => {
    const contracts = readFileSync(
      new URL("../../native/z/service-contract.zs", import.meta.url),
      "utf8",
    );
    const services = readFileSync(
      new URL("../../native/z/services.zs", import.meta.url),
      "utf8",
    );
    const notes = readFileSync(
      new URL("../../native/z/notes-service.zs", import.meta.url),
      "utf8",
    );

    expect(contracts).toContain("=> ServiceOutcome on thread.any");
    expect(services).toContain("function freeze(move this): Services");
    expect(services).toContain("readonly Map<String, ServiceHandler>");
    expect(notes).toContain("export readonly struct NotesService");
    expect(notes).toContain("readonly state: Mutex<NotesState>");
  });
});

describe("parseZCompilerIdentity", () => {
  it("decodes the pinned compiler contract", () => {
    expect(parseZCompilerIdentity("z 0.1.0-dev revision 2026-08-23 compiler-api 1\n"))
      .toEqual({
        languageVersion: "0.1.0-dev",
        compilerRevision: "2026-08-23",
        compilerApi: 1,
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
    compilerRevision: "2026-08-23",
    compilerApi: 1,
  };

  it("accepts the exact pinned identity", () => {
    expect(() => validateZCompilerIdentity(expected, expected, "compiler-contract.json"))
      .not.toThrow();
  });

  it("reports every incompatible compiler dimension", () => {
    expect(() => validateZCompilerIdentity(expected, {
      languageVersion: "0.2.0-dev",
      compilerRevision: "later",
      compilerApi: 2,
    }, "compiler-contract.json")).toThrow(
      /language 0\.2\.0-dev.*revision later.*compiler API 2.*compiler-contract\.json/,
    );
  });
});
