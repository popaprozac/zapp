import WebKit from "WebKit/WebKit.h";
import { thread } from "std/thread";
import { Channel } from "std/channel";
import process from "std/process";
import fs from "std/fs";
import json from "std/json";
import console from "std/console";
import { WindowOptions } from "../framework/window.zs";
import { SavedWindowState, WindowStateFile, WindowStateInbox, WindowStateStore } from "../framework/window-state.zs";
import { MacOSWindow } from "../framework/platform/macos/window-resize.zs";
import { restoreMacOSWindow } from "../framework/platform/macos/window-state.zs";
import { macOSWindowSize, macOSWindowBounds, macOSPrimaryScreen, boundsFromMacOSFrame } from "../framework/platform/macos/window-geometry.zs";
import { applyMacOSWindowPolicy } from "../framework/platform/macos/window-policy.zs";

struct Lifetime on thread.main { window: MacOSWindow; deinit { this.window.close(); } }
function near(left: f64, right: f64): boolean { return left - right < 1 && right - left < 1; }

function verify(): i32 on thread.main {
  const args = process.args();
  if (args.length != 1) return 1;
  const directory = copy args[0];
  match (attempt fs.createDirectories(directory)) { success => {} failure(_) => return 2; }
  let values = Array<SavedWindowState>(
    SavedWindowState({ key: "notes.main", width: 900, height: 300, x: 999999, y: -999999, maximized: false }),
    SavedWindowState({ key: "zoom", width: 540, height: 420, x: 80, y: 80, maximized: true }),
    SavedWindowState({ key: "fixed", width: 540, height: 420, x: 80, y: 80, maximized: true }));
  const file = WindowStateFile({ version: 1, windows: move values });
  const source = match (attempt json.encode(in file)) { success(value) => value; failure(_) => return 3; };
  match (attempt fs.writeText(`${directory}/window-state.json`, source)) { success => {} failure(_) => return 4; }
  const { sender, receiver } = Channel<boolean>.bounded(1);
  const inbox = new WindowStateInbox();
  let store = new WindowStateStore(copy directory, inbox, sender.sync());
  const app = WebKit.NSApplication.sharedApplication;
  app.setActivationPolicy(WebKit.NSApplicationActivationPolicyAccessory);
  const style = WebKit.NSWindowStyleMaskTitled | WebKit.NSWindowStyleMaskClosable | WebKit.NSWindowStyleMaskResizable;
  const window = new MacOSWindow(WebKit.NSMakeRect(0, 0, 400, 300), style);
  const lifetime = Lifetime({ window });
  const options = WindowOptions({ stateKey: Option.some("notes.main"), visible: false,
    minWidth: Option.some(u32(500)), maxWidth: Option.some(u32(650)), minHeight: Option.some(u32(400)) });
  const observer = match (restoreMacOSWindow(window, in options, store)) { some(value) => value; none => return 5; };
  const size = match (attempt macOSWindowSize(in window)) { success(value) => value; failure(_) => return 6; };
  if (size.width != 650 || size.height != 400 || window.visible) return 7;
  const primary = macOSPrimaryScreen();
  if (primary == null) return 8;
  const work = boundsFromMacOSFrame(primary.visibleFrame, primary.frame);
  const bounds = match (attempt macOSWindowBounds(in window)) { success(value) => value; failure(_) => return 9; };
  if (bounds.x < work.x || bounds.y < work.y || bounds.x + bounds.width > work.x + work.width + 1) return 10;
  observer.capture();
  const ordinary = match (store.find("notes.main")) { some(value) => value; none => return 11; };
  // Fullscreen-owned transitions must not overwrite ordinary geometry.
  window.setSystemResize(true);
  window.setFrame(primary.frame, display: false);
  observer.capture();
  const during = match (store.find("notes.main")) { some(value) => value; none => return 12; };
  if (during.width != ordinary.width || during.height != ordinary.height) return 13;
  window.setSystemResize(false);

  const zoom = new MacOSWindow(WebKit.NSMakeRect(0, 0, 400, 300), style);
  const zoomLifetime = Lifetime({ window: zoom });
  const zoomOptions = WindowOptions({ stateKey: Option.some("zoom"), visible: false });
  const zoomObserver = match (restoreMacOSWindow(zoom, in zoomOptions, store)) { some(value) => value; none => return 14; };
  if (!zoom.zoomed || zoom.visible) return 15;
  zoomObserver.capture();
  const savedZoom = match (store.find("zoom")) { some(value) => value; none => return 16; };
  if (savedZoom.width != 540 || savedZoom.height != 420 || !savedZoom.maximized) return 17;
  zoom.zoom(null);
  const unzoomed = match (attempt macOSWindowSize(in zoom)) { success(value) => value; failure(_) => return 18; };
  if (unzoomed.width != 540 || unzoomed.height != 420) return 19;
  const fixed = new MacOSWindow(WebKit.NSMakeRect(0, 0, 400, 300), style);
  const fixedLifetime = Lifetime({ window: fixed });
  applyMacOSWindowPolicy(fixed, false, false);
  const fixedOptions = WindowOptions({ stateKey: Option.some("fixed"), visible: false, maximizable: false, fullscreenable: false });
  const fixedObserver = restoreMacOSWindow(fixed, in fixedOptions, store);
  if (fixed.zoomed) return 20;
  // Opt-out never reads/writes a state slot or manufactures an observer.
  const defaults = WindowOptions();
  match (restoreMacOSWindow(fixed, in defaults, store)) { some(_) => return 21; none => {} }
  console.log("hidden AppKit restore, current limits, offscreen recovery, ordinary zoom geometry, fullscreen exclusion and policy passed");
  return 0;
}

function main(): i32 on thread.main { return verify(); }
