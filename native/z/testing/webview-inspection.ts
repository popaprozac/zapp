/** Bounded real WebKit checks for both compilers and generated build modes. */
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { resolve, join } from "node:path";
import assert from "node:assert/strict";
import { renderZConfiguredWebView } from "../../../cli/src/native-z";
import { runBoundedCommand } from "../../../cli/src/bounded-process";

if (process.platform !== "darwin") throw new Error("WebView inspection probe requires macOS");
const root = resolve(import.meta.dir, "../../..");
const zRoot = resolve(root, "../z-lang");
const cache = join(root, "native/z/.z-cache");
const interactive = process.argv.find((argument) => argument.startsWith("--interactive="))?.split("=")[1];
if (interactive && interactive !== "development" && interactive !== "production") {
  throw new Error("use --interactive=development or --interactive=production");
}
await mkdir(cache, { recursive: true });
const directory = await mkdtemp(join(cache, "inspection-"));
async function run(command: string[], timeoutMs: number): Promise<string> {
  const result = await runBoundedCommand(command, { cwd: root, timeoutMs });
  assert.equal(result.timedOut, false, `${command[0]} timed out`);
  assert.equal(result.status, 0, `${command.join(" ")}\n${result.stderr}\n${result.stdout}`);
  return result.stdout;
}
try {
  let fixture = await readFile(join(root, "native/z/tests/webview-inspection-native-smoke.zs"), "utf8");
  if (interactive) {
    fixture = fixture.replace("  return 0;\n}", `
  const configuration = WebKit.WKWebViewConfiguration.alloc().init();
  const inspectable = configuredWebViewInspectable();
  configureWebViewDeveloperExtras(in configuration, inspectable);
  const visible = new MacOSWebView(WebKit.NSMakeRect(0, 0, 650, 430), configuration, configuredFrontendIsDevelopment());
  visible.inspectable = inspectable;
  presentProbe(in visible);
  return 0;
}

function presentProbe(in view: WebKit.WKWebView): void on thread.main = raw objc {
  NSApplication *app = NSApplication.sharedApplication;
  [app setActivationPolicy:NSApplicationActivationPolicyRegular];
  NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(240, 300, 650, 430)
    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
    backing:NSBackingStoreBuffered defer:NO];
  window.releasedWhenClosed = NO;
  window.title = @"${interactive} Zapp inspection";
  window.contentView = view;
  [view loadHTMLString:@"<html><body style='font:22px system-ui;padding:40px'><h1>WebView inspection</h1><p>Right-click here for the native menu.</p><input value='Native editing menu'></body></html>" baseURL:nil];
  [window makeKeyAndOrderFront:nil];
  [app activateIgnoringOtherApps:YES];
  [NSTimer scheduledTimerWithTimeInterval:60 repeats:NO block:^(NSTimer *timer) {
    (void)timer;
    [app terminate:nil];
  }];
  [app run];
}
`);
  }
  for (const mode of ["production", "development"] as const) {
    if (interactive && interactive !== mode) continue;
    const config = join(directory, `configured-${mode}.zs`);
    const input = join(directory, `${mode}.zs`);
    await writeFile(config, renderZConfiguredWebView("", "zapp://app/", [], { mode }));
    await writeFile(input, fixture
      .replace('"../framework/platform/macos/configured-webview.zs"', JSON.stringify(`./configured-${mode}.zs`))
      .replaceAll('"../framework/', '"../../framework/'));
    for (const compiler of ["stage0", "native"] as const) {
      if (interactive && compiler !== "native") continue;
      const output = await run(compiler === "stage0"
        ? [process.execPath, join(zRoot, "compiler/src/cli.ts"), "emit", input]
        : [join(zRoot, ".z-cache/bootstrap/z"), "emit", input], 180_000);
      assert.equal(output.includes('forKey:@"developerExtrasEnabled"'), mode === "development");
      assert.equal(output.includes("_setDeveloperExtrasEnabled:"), mode === "development");
      const source = join(directory, `${mode}-${compiler}.m`);
      await writeFile(source, output);
      for (const optimization of ["-O0", "-O2"]) {
        if (interactive && optimization !== "-O0") continue;
        const bundle = join(directory, "Inspection Probe.app");
        const executable = interactive ? join(bundle, "Contents/MacOS/inspection")
          : join(directory, `${mode}-${compiler}${optimization}`);
        if (interactive) {
          await mkdir(join(bundle, "Contents/MacOS"), { recursive: true });
          await writeFile(join(bundle, "Contents/Info.plist"), `<?xml version="1.0"?><plist version="1.0"><dict>
            <key>CFBundleExecutable</key><string>inspection</string>
            <key>CFBundleIdentifier</key><string>com.zapp.inspection-probe</string>
            <key>CFBundleName</key><string>Inspection Probe</string>
            <key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
        }
        await run(["clang", "-std=c11", "-Wall", "-Wextra", "-Werror", optimization,
          "-fobjc-arc", "-fblocks", "-framework", "AppKit", "-framework", "WebKit",
          "-mmacosx-version-min=14.0", "-fsanitize=undefined", "-fno-sanitize-recover=all",
          source, "-o", executable], 30_000);
        if (interactive) console.log(`Inspection UI probe (closes after 60 seconds): ${bundle}`);
        await run([executable], interactive ? 75_000 : 15_000);
        console.log(`WebView inspection ${mode} ${compiler} ${optimization}: passed (UBSan)`);
      }
    }
  }
} finally { await rm(directory, { recursive: true, force: true }); }
