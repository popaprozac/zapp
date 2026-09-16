import WebKit from "WebKit/WebKit.h";
import { thread } from "std/thread";
import { MacOSWindow } from "./window-resize.zs";

// Separate native policies: edge resizing is a style bit; zoom and fullscreen
// are also enforced at the native action entry, not just by disabling a button.
internal function applyMacOSWindowPolicy(
  window: MacOSWindow, maximizable: boolean, fullscreenable: boolean
): void on thread.main {
  window.configurePresentation(maximizable, fullscreenable);
  let behavior = window.collectionBehavior;
  behavior = behavior & ~WebKit.NSWindowCollectionBehaviorFullScreenPrimary & ~WebKit.NSWindowCollectionBehaviorFullScreenAuxiliary
    & ~WebKit.NSWindowCollectionBehaviorFullScreenNone;
  window.collectionBehavior = behavior | (fullscreenable
    ? WebKit.NSWindowCollectionBehaviorFullScreenPrimary : WebKit.NSWindowCollectionBehaviorFullScreenNone);
  const zoom = window.standardWindowButton(WebKit.NSWindowZoomButton);
  if (zoom != null) zoom.enabled = maximizable || fullscreenable;
}
