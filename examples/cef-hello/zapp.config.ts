// `import type` is erased at compile time — no runtime resolution
// (the monorepo aliases only apply to the app bundle, not config loading).
//
// cef-hello — the minimal fullbleed-web fixture for the CEF
// `webEngine:"chromium"` production slice. Deliberately dead-simple: one
// window, one service, one button, no native chrome (no sidebar / inspector
// / toolbar — those aren't config-level concepts, they're WindowOptions in
// zapp/app.nim, and this app's window sets none of them). Its only job is
// to be the render+bridge smoke target for the CEF build/window-creation
// tasks that follow this one.
import type { ZappConfig } from "@zappdev/cli/config";

const config: ZappConfig = {
  name: "cef-hello",
  identifier: "com.zapp.cefhello",
  version: "0.1.0",
  // Early-access opt-in — accepted (with a warning) by validateWebEngine,
  // resolved via resolveWebEngine. `system` builds of this same app stay
  // on WKWebView and do zero CEF work; that's the byte-identical control
  // this fixture is meant to prove out in a later task.
  webEngine: "chromium",
};

export default config;
