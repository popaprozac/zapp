import WebKit from "WebKit/WebKit.h";
import { JsonValue, stringify } from "std/json";
import { thread } from "std/thread";
import {
  configuredWebViewBootstrap,
  configuredWebViewInjectionAtIndex,
  configuredWebViewInjectionCount,
} from "./configured-webview.zs";

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
  const count: usize = configuredWebViewInjectionCount();
  let index: usize = 0;
  while (index < count) {
    const candidate = configuredWebViewInjectionAtIndex(index);
    match (candidate) {
      some(entry) => {
        if (entry.profile == profile) return true;
      }
      none => {}
    }
    index = index + 1;
  }
  return false;
}

internal function installWebViewScripts(
  in contentController: WebKit.WKUserContentController,
  in windowId: String,
  in profiles: Array<String>
): void throws String on thread.main {
  addUserScript(contentController, configuredWebViewBootstrap(), 1);
  addUserScript(
    contentController,
    windowIdentityInjection(in windowId),
    1
  );

  const entryCount: usize = configuredWebViewInjectionCount();
  let selectedIndex: usize = 0;
  while (selectedIndex < profiles.length) {
    if (!profileWasSelected(in profiles, selectedIndex)) {
      let entryIndex: usize = 0;
      while (entryIndex < entryCount) {
        const configured = configuredWebViewInjectionAtIndex(entryIndex);
        match (configured) {
          some(entry) => {
            if (entry.profile == profiles[selectedIndex]) {
              let scriptSource = copy entry.source;
              if (entry.phase == 0) {
                scriptSource = styleInjection(move scriptSource);
              }
              addUserScript(contentController, move scriptSource, entry.phase);
            }
          }
          none => {}
        }
        entryIndex = entryIndex + 1;
      }
    }
    selectedIndex = selectedIndex + 1;
  }
}
