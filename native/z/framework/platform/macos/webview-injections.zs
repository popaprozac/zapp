import native from "zapp_desktop.h";
import Foundation from "Foundation/Foundation.h";
import WebKit from "WebKit/WebKit.h";
import { JsonValue, stringify } from "std/json";
import { thread } from "std/thread";

function quotedJavaScriptString(source: String): String {
  const value = JsonValue.string(move source);
  return stringify(in value);
}

function styleInjection(source: String): String {
  const css = quotedJavaScriptString(move source);
  return `(()=>{const css=${css};const install=()=>{const style=document.createElement('style');style.setAttribute('data-zapp-injected-style','');style.textContent=css;(document.head||document.documentElement).appendChild(style)};if(document.documentElement)install();else document.addEventListener('DOMContentLoaded',install,{once:true})})()`;
}

function windowIdentityInjection(in windowId: String): String {
  const encoded = quotedJavaScriptString(copy windowId);
  return `globalThis[Symbol.for('zapp.windowId')]=${encoded}`;
}

function addUserScript(
  in contentController: WebKit.WKUserContentController,
  source: String,
  phase: i32
): void on thread.main {
  const injectionTime = phase == 2
    ? WebKit.WKUserScriptInjectionTimeAtDocumentEnd
    : WebKit.WKUserScriptInjectionTimeAtDocumentStart;
  const script = WebKit.WKUserScript.alloc().initWithSource(
    move source,
    injectionTime: injectionTime,
    forMainFrameOnly: true
  );
  contentController.addUserScript(script);
}

function profileWasSelected(
  in profiles: Array<String>,
  selectedIndex: usize
): boolean {
  let index: usize = 0;
  while (index < selectedIndex) {
    if (profiles[index] == profiles[selectedIndex]) return true;
    index = index + 1;
  }
  return false;
}

internal function webViewInjectionProfileExists(
  in profile: String
): boolean on thread.main {
  const count: usize = native.ZAppDesktopBridge.webViewInjectionCount();
  let index: usize = 0;
  while (index < count) {
    const candidate: Foundation.NSString | null =
      native.ZAppDesktopBridge.webViewInjectionProfileAtIndex(index);
    if (
      candidate != null
      && candidate.isEqualToString(copy profile)
    ) return true;
    index = index + 1;
  }
  return false;
}

internal function installWebViewScripts(
  in contentController: WebKit.WKUserContentController,
  in windowId: String,
  in profiles: Array<String>
): void throws String on thread.main {
  const bootstrap: Foundation.NSString | null =
    native.ZAppDesktopBridge.webViewBootstrapScript();
  if (bootstrap == null) throw "could not decode the WebView bootstrap script";
  const bootstrapSource: String = bootstrap;
  addUserScript(contentController, move bootstrapSource, 1);
  addUserScript(
    contentController,
    windowIdentityInjection(in windowId),
    1
  );

  const entryCount: usize = native.ZAppDesktopBridge.webViewInjectionCount();
  let selectedIndex: usize = 0;
  while (selectedIndex < profiles.length) {
    if (!profileWasSelected(in profiles, selectedIndex)) {
      let entryIndex: usize = 0;
      while (entryIndex < entryCount) {
        const entryProfile: Foundation.NSString | null =
          native.ZAppDesktopBridge.webViewInjectionProfileAtIndex(entryIndex);
        if (
          entryProfile != null
          && entryProfile.isEqualToString(copy profiles[selectedIndex])
        ) {
          const source: Foundation.NSString | null =
            native.ZAppDesktopBridge.webViewInjectionSourceAtIndex(entryIndex);
          if (source == null) {
            throw `could not decode WebView inject profile "${profiles[selectedIndex]}"`;
          }
          let scriptSource: String = source;
          const phase =
            native.ZAppDesktopBridge.webViewInjectionPhaseAtIndex(entryIndex);
          if (phase == 0) scriptSource = styleInjection(move scriptSource);
          addUserScript(contentController, move scriptSource, phase);
        }
        entryIndex = entryIndex + 1;
      }
    }
    selectedIndex = selectedIndex + 1;
  }
}
