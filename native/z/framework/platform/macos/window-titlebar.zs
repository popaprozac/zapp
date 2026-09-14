import WebKit from "WebKit/WebKit.h";
import { thread } from "std/thread";
import { TitleBarOptions, TitleBarStyle } from "../../window-titlebar.zs";

internal function macOSTitleBarStyleMask(
  style: WebKit.NSWindowStyleMask, in options: TitleBarOptions
): WebKit.NSWindowStyleMask {
  return options.style == TitleBarStyle.default ? style : style | WebKit.NSWindowStyleMaskFullSizeContentView;
}

// Called during creation, before ordering the window front. Native AppKit
// layout owns the control inset; no hardcoded button coordinates or private API.
internal function applyMacOSTitleBar(
  in window: WebKit.NSWindow, in options: TitleBarOptions, in id: String
): void on thread.main {
  window.titlebarAppearsTransparent = options.style != TitleBarStyle.default;
  if (options.style == TitleBarStyle.hiddenInset) {
    // Identifiers are per-window: AppKit synchronizes toolbars sharing an ID.
    const toolbar = WebKit.NSToolbar.alloc().initWithIdentifier(`zapp-titlebar-${id}`);
    toolbar.allowsUserCustomization = false;
    toolbar.autosavesConfiguration = false;
    window.titlebarSeparatorStyle = WebKit.NSTitlebarSeparatorStyleNone;
    window.toolbarStyle = WebKit.NSWindowToolbarStyleUnified;
    window.toolbar = toolbar;
  }
  // Apply independently and last: neither style nor toolbar installation may
  // decide whether the actual native title label is visible.
  window.titleVisibility = options.titleVisible ? WebKit.NSWindowTitleVisible : WebKit.NSWindowTitleHidden;
}
