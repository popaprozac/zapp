import { test, expect } from "bun:test";
import { renderBuildConfigNim } from "./build-config";

test("renderBuildConfigNim emits exportc getters the .m layer calls", () => {
  const out = renderBuildConfigNim({
    initialUrl: "zapp://index.html",
    identifier: "com.example.app",
    assetRoot: "",
    embedAssets: true,
    devTools: 1,
    isDev: false,
  });
  expect(out).toContain('proc zapp_build_initial_url(): cstring {.exportc, cdecl.}');
  expect(out).toContain('proc zapp_build_use_embedded_assets(): cint {.exportc, cdecl.}');
  expect(out).toContain('"zapp://index.html"');
});

import { renderBootstrapNim } from "./build-config";
test("renderBootstrapNim emits the bootstrap script exportc, backed by a let", () => {
  const out = renderBootstrapNim("globalThis.__x=1;");
  expect(out).toContain('proc zapp_webview_bootstrap_script(): cstring {.exportc, cdecl.}');
  expect(out).toContain('let zappWebviewBootstrap');
});
