import WebKit from "WebKit/WebKit.h";
import objc from "std/objc";
import console from "std/console";
import { thread } from "std/thread";
import { MacOSWindow, windowPresentationNotification, queueWindowPresentation } from "../framework/platform/macos/window-resize.zs";
import { setMacOSNativeWindowMaximized } from "../framework/platform/macos/window-activation.zs";

class Observations on thread.main implements WebKit.NSWindowDelegate {
  allowZoom: boolean;
  stableNotifications: i32;
  function shouldZoom(in window: WebKit.NSWindow, frame: WebKit.CGRect): boolean as "windowShouldZoom:toFrame:" {
    return this.allowZoom;
  }
  function didResize(in notification: WebKit.NSNotification): void as "windowDidResize:" {
    // The production delegate queues observation during the guarded geometry
    // entry too; application callbacks must wait until that entry unwinds.
    const object = notification.object;
    if (object instanceof WebKit.NSWindow) queueWindowPresentation(object);
  }
}

struct WindowLifetime on thread.main {
  window: WebKit.NSWindow;
  deinit { this.window.delegate = null; this.window.close(); }
}
struct ObserverLifetime on thread.main {
  token: objc.Object;
  deinit { WebKit.NSNotificationCenter.defaultCenter.removeObserver(this.token); }
}
function sameFrame(left: WebKit.CGRect, right: WebKit.CGRect): boolean {
  return left.origin.x == right.origin.x && left.origin.y == right.origin.y
    && left.size.width == right.size.width && left.size.height == right.size.height;
}

class ProbeResult on thread.main {
  code: i32;
  phase: i32;
  ticks: i32;
  original: WebKit.CGRect;
  standard: WebKit.CGRect;
}

function advance(state: ProbeResult, window: MacOSWindow, observations: Observations): boolean on thread.main {
  state.ticks = state.ticks + 1;
  if (state.ticks > 160) {
    console.log(`zoom timeout: phase=${state.phase} stable=${window.presentationStable()} zoomed=${window.zoomed} occlusion=${usize(window.occlusionState)}`);
    state.code = 90;
    return true;
  }
  if (!window.presentationStable()) return false;
  if (state.phase == 0) {
    setMacOSNativeWindowMaximized(window, true);
    setMacOSNativeWindowMaximized(window, true);
  } else if (state.phase == 1) {
    if (!window.zoomed || sameFrame(state.original, window.frame)) { state.code = 1; return true; }
    if (observations.stableNotifications == 0) return false;
    state.standard = window.frame;
    setMacOSNativeWindowMaximized(window, true);
  } else if (state.phase == 2) {
    if (!sameFrame(state.standard, window.frame)) { state.code = 2; return true; }
    setMacOSNativeWindowMaximized(window, false);
    setMacOSNativeWindowMaximized(window, false);
  } else if (state.phase == 3) {
    if (window.zoomed || !sameFrame(state.original, window.frame)) { state.code = 3; return true; }
    observations.allowZoom = false;
    setMacOSNativeWindowMaximized(window, true);
  } else if (state.phase == 4) {
    if (window.zoomed || !sameFrame(state.original, window.frame)) { state.code = 4; return true; }
    observations.allowZoom = true;
    setMacOSNativeWindowMaximized(window, true);
    setMacOSNativeWindowMaximized(window, false);
    setMacOSNativeWindowMaximized(window, false);
  } else {
    if (window.zoomed || !sameFrame(state.original, window.frame)) { state.code = 5; return true; }
    state.code = 0;
    console.log("zoom probe: repeated requests, standard frame, restore, veto, reversal, deferred observation passed");
    return true;
  }
  state.phase = state.phase + 1;
  return false;
}

function main(): i32 on thread.main {
  const app = WebKit.NSApplication.sharedApplication;
  app.setActivationPolicy(WebKit.NSApplicationActivationPolicyRegular);
  const style = WebKit.NSWindowStyleMaskTitled | WebKit.NSWindowStyleMaskClosable | WebKit.NSWindowStyleMaskResizable;
  const window = new MacOSWindow(WebKit.NSMakeRect(200, 200, 360, 240), style);
  const lifetime = WindowLifetime({ window });
  window.title = "Zapp bounded zoom probe";
  const observations = new Observations({ allowZoom: true, stableNotifications: 0 });
  const delegate = objc.adapt<WebKit.NSWindowDelegate>(observations);
  window.delegate = delegate;
  window.makeKeyAndOrderFront(null);
  const original = window.frame;
  const observedWindow = window;
  const token = WebKit.NSNotificationCenter.defaultCenter.addObserverForName(
    windowPresentationNotification, object: window, queue: null,
    usingBlock: move (notification): void => {
      if (observedWindow.presentationStable()) {
        observations.stableNotifications = observations.stableNotifications + 1;
      }
    }
  );
  const observer = ObserverLifetime({ token });
  const result = new ProbeResult({ code: 99, phase: 0, ticks: 0, original, standard: original });
  const timer = WebKit.NSTimer.scheduledTimerWithTimeInterval(0.05, repeats: true,
    block: move (timer): void => {
      if (!advance(result, window, observations)) return;
      timer.invalidate();
      app.stop(null);
      const flags = WebKit.NSEventModifierFlagCapsLock ^ WebKit.NSEventModifierFlagCapsLock;
      const wake = WebKit.NSEvent.otherEventWithType(WebKit.NSEventTypeApplicationDefined,
        location: WebKit.NSMakePoint(0, 0), modifierFlags: flags, timestamp: 0,
        windowNumber: 0, context: null, subtype: 0, data1: 0, data2: 0);
      if (wake != null) app.postEvent(wake, atStart: true);
    }
  );
  app.activate();
  app.run();
  timer.invalidate();
  return result.code;
}
