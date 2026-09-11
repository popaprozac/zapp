// Verify the production Z controller, not a separate Objective-C implementation.
// --check opens no windows. --run is bounded GUI + strict Clang/UBSan (never ASan).
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { runBoundedCommand } from "../../cli/src/bounded-process";

const mode = process.argv[2];
const webview = process.argv.includes("--webview");
if (process.platform !== "darwin" || !["--check", "--run"].includes(mode ?? "")
  || process.argv.slice(3).some((argument) => argument !== "--webview")) {
  throw new Error("Usage: bun spikes/window-resize/verify-z.ts --check|--run [--webview]");
}
const root = resolve(import.meta.dir, "../..");
const zRoot = resolve(root, "../z-lang");
const compiler = process.env.ZAPP_Z_COMPILER ?? resolve(zRoot, ".z-cache/bootstrap/z");
const platform = resolve(root, "native/z/framework/platform/macos");
const original = readFileSync(resolve(platform, "window-resize.zs"), "utf8");
const temporary = mkdtempSync(resolve(tmpdir(), "zapp-resize-z-"));

const delegate = `
class ResizeDelegate on thread.main implements WebKit.NSWindowDelegate {
  readonly window: MacOSWindow;
  vetoZoom: boolean;
  vetoClose: boolean;
  resized: i32;
  function standardFrame(in window: WebKit.NSWindow, frame: WebKit.CGRect): WebKit.CGRect as "windowWillUseStandardFrame:defaultFrame:" {
    if (probe.z_subclass_access_scenario() == 18) return WebKit.NSMakeRect(80, 100, 520, 420);
    return frame;
  }
  function shouldZoom(in window: WebKit.NSWindow, frame: WebKit.CGRect): boolean as "windowShouldZoom:toFrame:" { return !this.vetoZoom; }
  function shouldClose(in window: WebKit.NSWindow): boolean as "windowShouldClose:" { return !this.vetoClose; }
  function didResize(inout this, in notification: WebKit.NSNotification): void as "windowDidResize:" { this.resized = this.resized + 1; }
  function willMove(inout this, in notification: WebKit.NSNotification): void as "windowWillMove:" { this.window.cancelResize(); }
}
`;
const scenarios = `
import probe from "./objc-subclass.h";
import console from "std/console";
function pump(seconds: f64): void on thread.main {
  const deadline = clock.CACurrentMediaTime() + seconds;
  while (clock.CACurrentMediaTime() < deadline) {
    WebKit.NSRunLoop.mainRunLoop.runUntilDate(WebKit.NSDate.dateWithTimeIntervalSinceNow(0.005));
  }
}
function near(left: f64, right: f64): boolean {
  return left - right < 1 && right - left < 1;
}
function sameFrame(left: WebKit.CGRect, right: WebKit.CGRect): boolean {
  return near(left.origin.x, right.origin.x) && near(left.origin.y, right.origin.y)
    && near(left.size.width, right.size.width) && near(left.size.height, right.size.height);
}
function printFrame(frame: WebKit.CGRect): void {
  console.error(\`(\${frame.origin.x}, \${frame.origin.y}, \${frame.size.width}, \${frame.size.height})\`);
}
function main(): i32 {
  probe.z_subclass_catch_abort();
  const app = WebKit.NSApplication.sharedApplication;
  const window = new MacOSWindow(WebKit.NSMakeRect(100, 100, 320, 240), WebKit.NSWindowStyleMaskTitled | WebKit.NSWindowStyleMaskClosable | WebKit.NSWindowStyleMaskResizable);
  window.makeKeyAndOrderFront(null);
  if (window.frame.size.width < 300) {
    console.error("WindowServer access required: the ordered window lost its requested geometry");
    window.close();
    return 3;
  }
  const delegate = new ResizeDelegate({ window, vetoZoom: false, vetoClose: false, resized: 0 });
  const adapter = objc.adapt<WebKit.NSWindowDelegate>(delegate);
  window.delegate = adapter;
  const original = window.frame;
  let expected = original;
  const enlarged = WebKit.NSMakeRect(original.origin.x, original.origin.y, original.size.width + 150, original.size.height + 100);
  const scenario = probe.z_subclass_access_scenario();
  if (scenario == 19) {
    window.zoom(null);
    pump(0.5);
    const maximized = window.frame;
    window.setSystemResize(true);
    window.setFrame(enlarged, true);
    window.setFrame(WebKit.NSMakeRect(enlarged.origin.x, enlarged.origin.y, enlarged.size.width + 20, enlarged.size.height + 20), true);
    window.setFrame(maximized, true);
    window.setSystemResize(false);
    window.zoom(null);
  } else if (scenario == 18) {
    const style = WebKit.NSWindowStyleMaskTitled | WebKit.NSWindowStyleMaskClosable | WebKit.NSWindowStyleMaskResizable;
    const oracle = WebKit.NSWindow.alloc().initWithContentRect(WebKit.NSMakeRect(100, 100, 320, 240), styleMask: style, backing: WebKit.NSBackingStoreBuffered, defer: false);
    oracle.releasedWhenClosed = false;
    oracle.delegate = adapter;
    oracle.contentMinSize = WebKit.NSMakeSize(360, 280);
    oracle.contentMaxSize = WebKit.NSMakeSize(600, 500);
    window.contentMinSize = WebKit.NSMakeSize(360, 280);
    window.contentMaxSize = WebKit.NSMakeSize(600, 500);
    oracle.zoom(null);
    pump(0.5);
    const nativeTarget = oracle.frame;
    oracle.close();
    window.zoom(null);
    pump(0.5);
    if (!sameFrame(window.frame, nativeTarget) || window.isAnimating()) return 181;
    window.close();
    console.log("delegate standard frame and content constraints match unmodified AppKit");
    return 0;
  } else if (scenario == 13 || scenario == 14) {
    if (scenario == 14) { window.zoom(null); pump(0.5); }
    const before = window.frame;
    delegate.vetoZoom = true;
    window.zoom(null);
    pump(0.5);
    if (window.isAnimating() || !sameFrame(window.frame, before)) return 131;
    window.close();
    console.log("delegate zoom veto preserved");
    return 0;
  } else if (scenario == 15 || scenario == 16) {
    window.resize(enlarged, true, true);
    pump(0.08);
    if (!window.isAnimating() || delegate.resized == 0) return 151;
    if (scenario == 15) window.cancelResize();
    else window.setSystemResize(true);
    const stopped = window.frame;
    const count = window.displayCallbacks();
    pump(0.3);
    if (window.isAnimating() || !sameFrame(window.frame, stopped) || window.displayCallbacks() != count) return 152;
    if (scenario == 16) window.setSystemResize(false);
    window.setFrame(original, true);
    window.resize(enlarged, true, true);
    pump(0.5);
    if (window.isAnimating() || !sameFrame(window.frame, enlarged)) return 153;
    window.setFrame(original, true);
  } else if (scenario == 17) {
    delegate.vetoClose = true;
    window.resize(enlarged, true, true);
    window.performClose(null);
    if (!window.isAnimating()) return 171;
    pump(0.5);
    if (!sameFrame(window.frame, enlarged)) return 172;
    delegate.vetoClose = false;
    window.performClose(null);
    console.log("close veto leaves transition alive; accepted close stops it");
    return 0;
  } else if (scenario == 0) {
    window.resize(enlarged, true, true);
    pump(0.5);
    if (!sameFrame(window.frame, enlarged) || window.isAnimating()) {
      console.error("transition failed to reach its target and stop");
      return 10;
    }
    const callbacks = window.displayCallbacks();
    if (callbacks == 0) return 11;
    pump(0.1);
    if (window.displayCallbacks() != callbacks) return 12;
    window.resize(original, true, true);
  } else if (scenario == 1) {
    window.resize(enlarged, true, true);
    pump(0.08);
    window.resize(original, true, true);
  } else if (scenario == 2) {
    window.resize(enlarged, true, true);
    pump(0.08);
    window.setFrame(original, true);
    if (window.isAnimating()) return 20;
  } else if (scenario == 3) {
    window.zoom(null);
    if (!window.isAnimating() || !window.zoomed) return 31;
    pump(0.5);
    if (sameFrame(window.frame, original) || window.isAnimating() || !window.zoomed) return 30;
    window.zoom(null);
    if (!window.isAnimating() || window.zoomed) return 32;
  } else if (scenario == 4) {
    window.zoom(null);
    pump(0.08);
    window.zoom(null);
  } else if (scenario == 5) {
    window.resize(enlarged, true, true);
    pump(0.08);
    window.close();
    const callbacks = window.displayCallbacks();
    pump(0.25);
    if (window.isAnimating() || window.displayCallbacks() != callbacks) return 50;
    console.log("close cancelled display callbacks");
    return 0;
  } else if (scenario == 6) {
    window.resize(enlarged, true, true);
    if (window.isAnimating() || !sameFrame(window.frame, enlarged) || window.displayCallbacks() != 0) return 60;
    window.setFrame(original, true);
  } else if (scenario == 7 || scenario == 8) {
    window.zoom(null);
    pump(0.5);
    if (!window.zoomed) return 71;
    const maximized = window.frame;
    // Moving a maximized window must not replace the saved user frame.
    window.setFrameOrigin(WebKit.NSMakePoint(maximized.origin.x + 12, maximized.origin.y - 12));
    const movedIsZoomed = window.zoomed;
    if (scenario == 8) {
      // Once outside the standard frame, a subsequent user size change is
      // the new restore geometry rather than the original pre-zoom geometry.
      window.setFrame(enlarged, true);
      expected = window.frame;
      window.zoom(null);
      pump(0.5);
      if (!window.zoomed) return 81;
    }
    window.zoom(null);
    if (scenario == 7 && !movedIsZoomed) {
      // AppKit may regard the moved frame as nonstandard and maximize again
      // first. Preserve that native toggle, then verify the saved user frame.
      pump(0.5);
      if (!window.zoomed) return 72;
      window.zoom(null);
    }
  } else if (scenario == 9) {
    window.resize(original, true, true);
    if (window.isAnimating() || window.displayCallbacks() != 0) return 91;
  } else if (scenario == 10) {
    window.resize(enlarged, true, true);
    pump(0.08);
    if (!window.isAnimating()) return 101;
    window.reduceMotion();
    pump(0.1);
    if (window.isAnimating() || !sameFrame(window.frame, enlarged)) return 102;
    const callbacks = window.displayCallbacks();
    pump(0.1);
    if (window.displayCallbacks() != callbacks) return 103;
    window.setFrame(original, true);
  } else if (scenario == 11) {
    window.resize(enlarged, true, true);
    if (window.isAnimating() || !sameFrame(window.frame, enlarged) || window.displayCallbacks() != 0) return 111;
    window.setFrame(original, true);
  } else if (scenario == 12) {
    // A different native link represents a late callback from an old source.
    // Never schedule it: only the controller's current link may move the frame.
    const stale = window.displayLinkWithTarget(window, selector: objc.selector(MacOSWindow.onDisplay));
    window.resize(enlarged, true, true);
    if (!window.isAnimating()) return 121;
    const before = window.frame;
    const callbacks = window.displayCallbacks();
    window.onDisplay(stale);
    if (!sameFrame(window.frame, before) || !window.isAnimating()) return 122;
    if (window.displayCallbacks() != callbacks + 1) return 123;
    pump(0.5);
    if (!sameFrame(window.frame, enlarged) || window.isAnimating()) return 124;
    window.setFrame(original, true);
  }
  pump(0.5);
  if (!sameFrame(window.frame, expected) || window.isAnimating()) {
    console.error("expected frame (x, y, width, height):");
    printFrame(expected);
    console.error("observed frame:");
    printFrame(window.frame);
    if (window.isAnimating()) console.error("still animating");
    window.close();
    return 70;
  }
  window.close();
  console.log("reached expected frame and stopped");
  return 0;
}
`;

const pageObserver = `
import probe from "./objc-subclass.h";
import console from "std/console";
class PageObserver on thread.main implements WebKit.WKScriptMessageHandler {
  readonly window: WebKit.NSWindow;
  status: i32;
  function receive(inout this, in controller: WebKit.WKUserContentController, in message: WebKit.WKScriptMessage): void as "userContentController:didReceiveScriptMessage:" {
    const body = message.body;
    if (body instanceof WebKit.NSString) {
      const text: String = body;
      console.log(text);
      if (text == "ready") {
        this.window.zoom(null);
      } else {
        this.status = text == "resized" ? 1 : -1;
        this.window.close();
      }
    }
  }
}
`;
const page = `<!doctype html><style>body{background:#15212b;color:white}#edge{position:fixed;bottom:0;right:0}</style>
<h1>Real WebView resize verification</h1><div id="edge">edge</div><script>
const initial=innerWidth;const sizes=new Set([initial]);
addEventListener('error',()=>webkit.messageHandlers.probe.postMessage('error'));
function observe(){sizes.add(innerWidth);requestAnimationFrame(observe)}
requestAnimationFrame(()=>requestAnimationFrame(()=>{
  observe();webkit.messageHandlers.probe.postMessage('ready');
  setTimeout(()=>{const edge=document.getElementById('edge').getBoundingClientRect();
    const passed=sizes.size>3&&innerWidth>initial&&Math.abs(edge.right-innerWidth)<2;
    webkit.messageHandlers.probe.postMessage(passed?'resized':'failed: '+JSON.stringify({initial,final:innerWidth,sizes:[...sizes],edgeRight:edge.right}));
  },1200);
}));</script>`;

const webviewMain = `
function main(): i32 {
  probe.z_subclass_catch_abort();
  const app = WebKit.NSApplication.sharedApplication;
  app.setActivationPolicy(WebKit.NSApplicationActivationPolicyRegular);
  const window = new MacOSWindow(WebKit.NSMakeRect(100, 100, 640, 440), WebKit.NSWindowStyleMaskTitled | WebKit.NSWindowStyleMaskClosable | WebKit.NSWindowStyleMaskResizable);
  window.title = "Z display-link resize probe";
  // This probe covers zoom, not system-owned fullscreen transitions.
  window.collectionBehavior = WebKit.NSWindowCollectionBehaviorFullScreenNone;
  const configuration = WebKit.WKWebViewConfiguration.new();
  configuration.websiteDataStore = WebKit.WKWebsiteDataStore.nonPersistentDataStore();
  const webview = WebKit.WKWebView.alloc().initWithFrame(WebKit.CGRectMake(0, 0, 640, 440), configuration: configuration);
  window.contentView = webview;
  const delegate = new ResizeDelegate({ window, vetoZoom: false, vetoClose: false, resized: 0 });
  const adapter = objc.adapt<WebKit.NSWindowDelegate>(delegate);
  window.delegate = adapter;
  const observer = new PageObserver({ window, status: 0 });
  const contentController = configuration.userContentController;
  const registration = objc.register({
    add: contentController.addScriptMessageHandler(observer, "probe"),
    remove: contentController.removeScriptMessageHandlerForName("probe"),
  });
  webview.loadHTMLString(${JSON.stringify(page)}, baseURL: null);
  window.makeKeyAndOrderFront(null);
  const center = WebKit.NSNotificationCenter.defaultCenter;
  const closeObserver = center.addObserverForName(
    WebKit.NSWindowWillCloseNotification,
    object: window,
    queue: null,
    usingBlock: move (notification): void => {
      app.stop(null);
      const emptyModifiers = WebKit.NSEventModifierFlagCapsLock ^ WebKit.NSEventModifierFlagCapsLock;
      const wakeEvent = WebKit.NSEvent.otherEventWithType(
        WebKit.NSEventTypeApplicationDefined,
        location: WebKit.NSMakePoint(0, 0), modifierFlags: emptyModifiers,
        timestamp: 0, windowNumber: 0, context: null, subtype: 0, data1: 0, data2: 0
      );
      if (wakeEvent != null) app.postEvent(wakeEvent, atStart: true);
    }
  );
  app.activate();
  // AppKit must dispatch events, not merely service Foundation run-loop sources.
  // The retained observer stops and wakes this loop when the window closes.
  app.run();
  center.removeObserver(closeObserver);
  if (observer.status != 1 || delegate.resized < 3) return 90;
  console.log("WebView readiness, intermediate viewport sizes, resize notifications, and clean shutdown verified");
  return 0;
}
`;

async function command(args: string[], timeoutMs = 60_000, env?: Record<string, string>) {
  const result = await runBoundedCommand(args, { cwd: temporary, timeoutMs, env });
  assert.equal(result.timedOut, false, args.join(" "));
  assert.equal(result.status, 0, `${args.join(" ")} scenario=${env?.Z_SUBCLASS_ACCESS_SCENARIO ?? "n/a"}\n${result.stdout}${result.stderr}`);
  return result.stdout;
}
try {
  symlinkSync(resolve(platform, "WebKit.h.zd"), resolve(temporary, "WebKit.h.zd"));
  for (const name of ["objc-subclass.h", "objc-subclass.h.zd"]) {
    symlinkSync(resolve(zRoot, "tests/fixtures", name), resolve(temporary, name));
  }
  for (const reduced of webview ? [false] : [false, true]) {
    const candidate = original.replace("internal class MacOSWindow", "class MacOSWindow")
      .replace("  private displayLink:", "  private callbacks: i32;\n  private testReducedMotion: boolean;\n  private displayLink:")
      .replace("    this.displayLink = null;", `    this.callbacks = 0;\n    this.testReducedMotion = ${reduced};\n    this.displayLink = null;`)
      .replace("    const active = this.displayLink;", "    this.callbacks = this.callbacks + 1;\n    const active = this.displayLink;")
      .replace("  function cancelResize(", `  function isAnimating(): boolean as "zResizeAnimating" { return this.animating; }
  function displayCallbacks(): i32 as "zResizeCallbacks" { return this.callbacks; }
  function reduceMotion(inout this): void as "zResizeReduceMotion" { this.testReducedMotion = true; }
  function cancelResize(`)
      .replaceAll("WebKit.NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion", "this.testReducedMotion")
      .replaceAll("const screen = this.screen;", `let screen: WebKit.NSScreen | null = this.screen;
    if (probe.z_subclass_access_scenario() == 11) screen = null;`)
      .replace(/const duration = super\.animationResizeTime\((frame|target)\);/g, "const duration: f64 = 0.25;")
      + delegate + (webview ? pageObserver + webviewMain : scenarios);
    const input = resolve(temporary, "main.zs");
    const generated = resolve(temporary, "main.m");
    writeFileSync(input, candidate);
    writeFileSync(generated, await command([compiler, "emit", input], 120_000));
    const flags = ["-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-mmacosx-version-min=14.0", "-I", resolve(zRoot, "tests/fixtures")];
    if (mode === "--check") {
      await command(["xcrun", "clang", ...flags, "-fsyntax-only", generated]);
      console.log(`production controller reduceMotion=${reduced}: checked`);
      continue;
    }
    for (const optimization of ["-O0", "-O2"]) {
      const executable = resolve(temporary, "probe");
      await command(["xcrun", "clang", optimization, ...flags, "-fsanitize=undefined", "-fno-sanitize-recover=all",
        "-framework", "AppKit", "-framework", "QuartzCore", "-framework", "WebKit", generated,
        resolve(zRoot, "tests/fixtures/objc-subclass.m"), "-o", executable]);
      for (const scenario of webview ? [0] : reduced ? [6] : [0, 1, 2, 3, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19]) {
        const result = await command([executable], webview ? 15_000 : 8_000, { Z_SUBCLASS_ACCESS_SCENARIO: String(scenario) });
        console.log(`${optimization} scenario ${scenario}: ${result.trim()}`);
      }
    }
  }
} finally {
  if (process.env.ZAPP_KEEP_RESIZE_PROBE === "1") console.log(`Probe source retained at ${temporary}`);
  else rmSync(temporary, { recursive: true, force: true });
}
