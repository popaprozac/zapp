import WebKit from "WebKit/WebKit.h";
import { showMacOSNativeWindow, focusMacOSNativeWindow,
  minimizeMacOSNativeWindow, unminimizeMacOSNativeWindow,
  setMacOSNativeWindowMaximized, setMacOSNativeWindowFullscreen } from "./window-activation.zs";
import { configuredApplicationQuitOnLastWindowClosed } from "../../configured-application.zs";
import { WindowError } from "../../application-error.zs";
import { ApplicationCapabilities, CapabilitySelection } from "../../application-capabilities.zs";
import { ApplicationMenu } from "../../application-menu.zs";
import { ContextMenuSessions } from "../../context-menu.zs";
import { BridgeResponse } from "../../bridge.zs";
import { BridgeDocument } from "../../bridge-document.zs";
import { RelatedDocuments, RelatedDocumentIdentity } from "../../related-documents.zs";
import { RelatedWindowCreations, RelatedWindowReservation, RelatedCreationReply } from "../../related-window-creations.zs";
import { MacOSRelatedWindows } from "./related-window-creations.zs";
import { Map } from "std/collections";
import { thread } from "std/thread";
import { WindowManager, WindowOptions } from "../../window.zs";
import { stopMacOSRunLoop } from "./application-host.zs";
import { DesktopRouteMessageOperation } from "./document-transport.zs";
import { createMacOSWindowRuntime } from "./window-construction.zs";
import { MacOSWindowRuntime } from "./window-runtime.zs";
import { deliverWebViewApplicationWorkerMessage, deliverWebViewApplicationQuitRequested,
  deliverWebViewMenuCommand, deliverWebViewResponse } from "./response-delivery.zs";
import { webViewInjectionProfileExists } from "./webview-injections.zs";
import { configuredNavigationProfileExists } from "./configured-webview.zs";
import { NativeWindowClosedOperation } from "./window-delegate.zs";

// Platform-owned window state. Application/worker lifetime remains in
// application-runtime; no callback captures the application ARC owner.
internal class MacOSWindowRegistry on thread.main {
  readonly name: String;
  readonly capabilities: ApplicationCapabilities;
  readonly windowManager: WindowManager;
  readonly menu: ApplicationMenu;
  readonly contextMenus: ContextMenuSessions;
  readonly routeMessage: DesktopRouteMessageOperation;
  readonly documents: RelatedDocuments;
  readonly creations: RelatedWindowCreations;
  readonly related: MacOSRelatedWindows;
  readonly didCloseNativeWindow: NativeWindowClosedOperation;
  nativeWindows: Map<i32, MacOSWindowRuntime>;
  retiredNativeWindows: Array<MacOSWindowRuntime>;
  nextNativeWindowId: i32;

  function createWindow(
    inout this,
    in id: String,
    in options: WindowOptions
  ): void throws WindowError on thread.main {
    for (const profile of options.capabilities) {
      if (!this.capabilities.hasProfile(profile)) {
        throw WindowError({
          id: copy id,
          message: `unknown window capability profile "${profile}"`,
        });
      }
    }
    const selected = this.capabilities.resolveProfiles(in options.capabilities);
    match (selected) {
      some(selection) => {
        try this.createResolvedWindow(in id, in options, selection);
        return;
      }
      none => throw WindowError({
        id: copy id,
        message: "could not resolve window capability profiles",
      });
    }
  }

  function createResolvedWindow(
    inout this,
    in id: String,
    in options: WindowOptions,
    selectedCapabilities: CapabilitySelection
  ): void throws WindowError on thread.main {
    if (!configuredNavigationProfileExists(options.navigation)) {
      throw WindowError({
        id: copy id,
        message: `unknown window navigation profile "${options.navigation}"`,
      });
    }
    for (const profile of options.inject) {
      if (!webViewInjectionProfileExists(profile)) {
        throw WindowError({
          id: copy id,
          message: `unknown webview inject profile "${profile}"`,
        });
      }
    }
    const nativeId = this.nextNativeWindowId;
    this.nextNativeWindowId = this.nextNativeWindowId + 1;
    const windowManager = this.windowManager;
    const windowManagerOwner = weak windowManager;
    const didClose = this.didCloseNativeWindow;
    const document = new BridgeDocument(nativeId, this.documents, selectedCapabilities);
    const runtime = try createMacOSWindowRuntime(
      copy this.name,
      in id,
      nativeId,
      in options,
      selectedCapabilities,
      document,
      windowManagerOwner,
      this.routeMessage,
      didClose,
      this.contextMenus,
      this.menu,
      this.related
    );
    this.nativeWindows.set(nativeId, runtime);
  }

  // Native-only until the public factory's remaining lifecycle gates are met.
  // Callers supply the authenticated document, never a renderer-chosen owner.
  function prepareRelatedWindow(inout this, in owner: RelatedDocumentIdentity,
    title: String, width: u32, height: u32, reply: RelatedCreationReply
  ): Option<RelatedWindowReservation> {
    const found = this.nativeWindows.get(owner.windowId);
    const runtime: MacOSWindowRuntime = match (in found) { some(value) => value; none => return Option.none; };
    if (this.nextNativeWindowId == 2147483647) return Option.none;
    const nativeId = this.nextNativeWindowId;
    this.nextNativeWindowId = nativeId + 1;
    const logicalOwner = match (this.windowManager.get(in runtime.id)) { some(value) => value; none => return Option.none; };
    return this.related.prepare(runtime.document, runtime.webView, logicalOwner, in owner, nativeId, move title, width, height, reply);
  }

  function nativeWindowClosed(
    inout this,
    nativeId: i32
  ): void on thread.main {
    const found = this.nativeWindows.remove(nativeId);
    match (found) {
      some(value) => {
        let window = value;
        this.contextMenus.invalidateWindow(in window.id);
        window.document.close();
        this.related.pruneInvalidated();
        let menu = this.menu;
        menu.invalidateFrontendOwner(in window.id);
        this.retiredNativeWindows.push(move window);
        if (this.nativeWindows.length == 0 && configuredApplicationQuitOnLastWindowClosed()) {
          stopMacOSRunLoop();
        }
      }
      none => {
        match (this.related.logicalWindowId(nativeId)) {
          some(id) => {
            this.contextMenus.invalidateWindow(in id);
            this.menu.invalidateFrontendOwner(in id);
          }
          none => {}
        }
      }
    }
  }

  function closeAllNativeWindows(inout this): void on thread.main {
    this.related.closeAll();
    this.contextMenus.invalidateAll();
    // Teardown is already committed, so it bypasses cancellable user close
    // requests. Snapshot the native windows first because close callbacks
    // synchronously remove entries from the live registry.
    let windows = Array<MacOSWindowRuntime>();
    for (const entry of this.nativeWindows) {
      let window = entry.value;
      windows.push(move window);
    }
    for (const window of windows) {
      window.window.close();
    }
  }

  function showWindow(in id: String): void on thread.main {
    const found = this.nativeWindow(in id);
    match (found) {
      some(window) => showMacOSNativeWindow(in window.window);
      none => {}
    }
  }

  function focusWindow(in id: String): void on thread.main {
    // Keep an owned runtime reference, not a live Map iteration/view, across
    // AppKit's synchronous focus callbacks, which may close this window.
    const found = this.nativeWindow(in id);
    match (found) {
      some(window) => focusMacOSNativeWindow(in window.window);
      none => {}
    }
  }

  function minimizeWindow(in id: String): void on thread.main {
    let sessions = this.contextMenus;
    sessions.invalidateWindow(in id);
    const found = this.nativeWindow(in id);
    match (found) {
      some(window) => minimizeMacOSNativeWindow(in window.window);
      none => {}
    }
  }

  function unminimizeWindow(in id: String): void on thread.main {
    const found = this.nativeWindow(in id);
    match (found) {
      some(window) => unminimizeMacOSNativeWindow(in window.window);
      none => {}
    }
  }

  function setWindowMaximized(in id: String, value: boolean): void on thread.main {
    const found = this.nativeWindow(in id);
    match (found) {
      some(window) => setMacOSNativeWindowMaximized(in window.window, value);
      none => {}
    }
  }

  function setWindowFullscreen(in id: String, value: boolean): void on thread.main {
    const found = this.nativeWindow(in id);
    match (found) {
      some(window) => {
        const current = usize(window.window.styleMask & WebKit.NSWindowStyleMaskFullScreen) != 0;
        // Refusal/no-op must release the logical transition rather than leave
        // later requests waiting for a delegate notification that cannot fire.
        if (current == value || usize(window.window.styleMask & WebKit.NSWindowStyleMaskResizable) == 0) {
          let windows = this.windowManager;
          windows.fullscreenChangedNative(in id, current);
          return;
        }
        setMacOSNativeWindowFullscreen(in window.window, value);
      }
      none => {}
    }
  }

  function hideWindow(in id: String): void on thread.main {
    let sessions = this.contextMenus;
    sessions.invalidateWindow(in id);
    const found = this.nativeWindow(in id);
    match (found) {
      some(window) => window.window.orderOut(null);
      none => {}
    }
  }

  function requestWindowClose(in id: String): void on thread.main {
    match (this.nativeWindow(in id)) {
      some(window) => {
        // performClose follows AppKit's normal delegate decision path and
        // therefore reaches WindowCloseRequestedEvent before committing.
        window.window.performClose(null);
      }
      none => {}
    }
  }

  function setWindowTitle(
    in id: String,
    in title: String
  ): void on thread.main {
    match (this.nativeWindow(in id)) {
      some(window) => window.window.title = copy title;
      none => {}
    }
  }

  function nativeWindow(in id: String): Option<MacOSWindowRuntime> on thread.main {
    for (const entry of this.nativeWindows) {
      if (entry.value.id == id) return Option.some(entry.value);
    }
    return this.related.nativeWindow(in id);
  }

  function logicalWindowId(
    nativeWindowId: i32
  ): Option<String> on thread.main {
    const found = this.nativeWindows.get(nativeWindowId);
    return match (in found) {
      some(window) => Option.some(copy window.id);
      none => this.related.logicalWindowId(nativeWindowId);
    };
  }

  function deliverMenuCommand(
    nativeWindowId: i32,
    in ownerToken: String,
    in commandId: String
  ): void on thread.main {
    const found = this.nativeWindows.get(nativeWindowId);
    match (in found) {
      some(window) => deliverWebViewMenuCommand(
        window.webView,
        in ownerToken,
        in commandId
      );
      none => {}
    }
  }

  function deliverQuitRequested(cancelled: boolean): void on thread.main {
    for (const entry of this.nativeWindows) {
      deliverWebViewApplicationQuitRequested(entry.value.webView, cancelled);
    }
  }

  function deliverApplicationWorkerMessage(
    in workerId: String,
    in channel: String,
    in payload: String
  ): void on thread.main {
    for (const entry of this.nativeWindows) {
      if (entry.value.capabilitySelection.allowsWorker(in workerId)) {
        deliverWebViewApplicationWorkerMessage(
          entry.value.webView,
          in workerId,
          in channel,
          in payload
        );
      }
    }
  }

  function deliverResponse(
    in response: BridgeResponse,
    document: RelatedDocumentIdentity
  ): void on thread.main {
    if (!this.documents.isReady(in document)) return;
    const windowId = document.windowId;
    const activeWindowCount = this.nativeWindows.length;
    const found = this.nativeWindows.get(windowId);
    match (in found) {
      some(window) => deliverWebViewResponse(
        window.webView,
        window.window,
        in response,
        document,
        window.document,
        windowId,
        activeWindowCount
      );
      none => {
        match (this.related.runtime(in document)) {
          some(window) => deliverWebViewResponse(window.webView, window.window,
            in response, document, window.document, windowId, activeWindowCount);
          none => {}
        }
      }
    }
  }
}
