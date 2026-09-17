import WebKit from "WebKit/WebKit.h";
import { thread } from "std/thread";
import { WindowOptions, windowSizeLimits } from "../../window.zs";
import { WindowSize } from "../../events.zs";
import { checkedWindowSize } from "../../window-sizing.zs";
import { Bounds } from "../../window-display.zs";
import { WindowPosition } from "../../window-positioning.zs";
import { SavedWindowState, WindowStateStore, recoveredWindowPosition } from "../../window-state.zs";
import { MacOSWindow } from "./window-resize.zs";
import { macOSPrimaryScreen, boundsFromMacOSFrame, positionFromMacOSFrame,
  positionedMacOSFrame, macOSContentDimension } from "./window-geometry.zs";

internal class MacOSWindowStateObserver on thread.main {
  readonly key: String;
  readonly window: MacOSWindow;
  readonly store: WindowStateStore;

  function capture(): void {
    const primary = macOSPrimaryScreen();
    if (primary == null) return;
    const frame = match (this.window.restorationFrame()) { some(value) => value; none => return; };
    const content = this.window.contentRectForFrameRect(frame);
    const position = positionFromMacOSFrame(frame, primary.frame);
    const resizable = usize(this.window.styleMask & WebKit.NSWindowStyleMaskResizable) != 0;
    let store = this.store;
    store.remember(SavedWindowState({ key: copy this.key,
      width: macOSContentDimension(content.size.width), height: macOSContentDimension(content.size.height),
      x: position.x, y: position.y, maximized: resizable && this.window.zoomed }));
  }
}

function overlap(left: Bounds, right: Bounds): f64 {
  const x = left.x > right.x ? left.x : right.x;
  const y = left.y > right.y ? left.y : right.y;
  const endX = left.x + left.width < right.x + right.width ? left.x + left.width : right.x + right.width;
  const endY = left.y + left.height < right.y + right.height ? left.y + left.height : right.y + right.height;
  return endX > x && endY > y ? (endX - x) * (endY - y) : f64(0);
}

internal function restoreMacOSWindow(window: MacOSWindow, in options: WindowOptions,
  store: WindowStateStore): Option<MacOSWindowStateObserver> on thread.main {
  const key = match (in options.stateKey) { some(value) => copy value; none => return Option.none; };
  let owner = store;
  const saved = owner.find(in key);
  const primary = macOSPrimaryScreen();
  if (primary != null) {
    match (in saved) {
      some(state) => {
        const size = match (attempt checkedWindowSize(WindowSize({ width: state.width, height: state.height }), windowSizeLimits(in options))) {
          success(value) => value;
          failure(_) => WindowSize({ width: options.width, height: options.height });
        };
        const frame = window.frameRectForContentRect(WebKit.NSMakeRect(0, 0, f64(size.width), f64(size.height)));
        const desired = Bounds({ x: state.x, y: state.y, width: frame.size.width, height: frame.size.height });
        let workArea = boundsFromMacOSFrame(primary.visibleFrame, primary.frame);
        let area = overlap(desired, workArea);
        const screens = WebKit.NSScreen.screens;
        let index: usize = 0;
        while (index < screens.count) {
          const object = screens.objectAtIndex(index);
          if (object instanceof WebKit.NSScreen) {
            const candidate = boundsFromMacOSFrame(object.visibleFrame, primary.frame);
            const candidateArea = overlap(desired, candidate);
            if (candidateArea > area) { area = candidateArea; workArea = candidate; }
          }
          index = index + 1;
        }
        const position = recoveredWindowPosition(WindowPosition({ x: state.x, y: state.y }),
          frame.size.width, frame.size.height, workArea);
        const target = positionedMacOSFrame(frame, position, primary.frame);
        window.setFrame(target, display: false);
        if (state.maximized && options.maximizable && options.resizable) window.zoom(null);
      }
      none => {}
    }
  }
  const observer = new MacOSWindowStateObserver({ key: move key, window, store });
  return Option.some(observer);
}
