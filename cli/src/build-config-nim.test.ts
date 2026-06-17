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
    permissionsJson: '{"platform":"macos","active":false,"allow":[]}',
    fsAllowlistJson: "[]",
    fsPersistGrants: false,
  });
  expect(out).toContain('proc zapp_build_initial_url(): cstring {.exportc, cdecl.}');
  expect(out).toContain('proc zapp_build_use_embedded_assets(): cint {.exportc, cdecl.}');
  expect(out).toContain('"zapp://index.html"');
});

import { renderBootstrapNim, renderHeadlessNim } from "./build-config";
test("renderBootstrapNim emits webview + worker bootstrap getters, backed by lets", () => {
  const out = renderBootstrapNim("globalThis.__x=1;", "globalThis.__w=2;");
  expect(out).toContain('proc zapp_webview_bootstrap_script(): cstring {.exportc, cdecl.}');
  expect(out).toContain('let zappWebviewBootstrap');
  // Worker twin — emitted from the 2nd arg so zjs workers get their bridge JS.
  expect(out).toContain('proc zapp_worker_bootstrap_script(): cstring {.exportc, cdecl, gcsafe.}');
  expect(out).toContain('let zappWorkerBootstrap');
  expect(out).toContain('globalThis.__w=2;');
});

test("renderHeadlessNim emits zjs_worker_create for zjs entries, skips non-zjs", () => {
  const out = renderHeadlessNim({
    "bench-zjs": { script: "src/bench-worker.ts", engine: "zjs" },
    "bench-bare-jsc": { script: "src/bench-worker.ts", engine: "bare-jsc" },
  });
  // zjs entry → spawn call with the dist/_workers URL + h-<id> worker id.
  expect(out).toContain(
    'discard zjs_worker_create(cstring"/_workers/_headless_bench-zjs.mjs", cstring"", cstring"h-bench-zjs")',
  );
  // non-zjs entry → no spawn call.
  expect(out).not.toContain("bench-bare-jsc");
  expect(out).toContain("proc zapp_start_headless_workers*()");
});

test("renderHeadlessNim with no zjs entries emits a discard body", () => {
  const out = renderHeadlessNim({ "x": { script: "a.ts", engine: "bare-jsc" } });
  expect(out).toContain("proc zapp_start_headless_workers*() =\n  discard");
});

test("renderBuildConfigNim emits zapp_build_permissions_json from the manifest", () => {
  const out = renderBuildConfigNim({
    initialUrl: "zapp://index.html",
    identifier: "com.example.app",
    assetRoot: "",
    embedAssets: true,
    devTools: 1,
    isDev: false,
    permissionsJson: '{"platform":"macos","active":true,"allow":["clipboard"]}',
    fsAllowlistJson: "[]",
    fsPersistGrants: false,
  });
  expect(out).toContain('proc zapp_build_permissions_json(): cstring {.exportc, cdecl.}');
  expect(out).toContain('let zappPermissionsJson');
  expect(out).toContain('clipboard');
});

test("renderBuildConfigNim emits fs allowlist + persist-grants getters", () => {
  const out = renderBuildConfigNim({
    initialUrl: "zapp://index.html",
    identifier: "com.zapp.test",
    assetRoot: "/tmp/assets",
    embedAssets: false,
    devTools: 1,
    isDev: true,
    permissionsJson: '{"platform":"macos","active":false,"allow":[]}',
    fsAllowlistJson: '["$userData","/tmp/zapp"]',
    fsPersistGrants: true,
  });
  // The allowlist JSON is embedded as a Nim string literal whose VALUE is the
  // raw array (fs.nim's parser reads it via std/json).
  expect(out).toContain('let zappFsAllowlistJson = "[\\"$userData\\",\\"/tmp/zapp\\"]"');
  expect(out).toContain("proc zapp_build_fs_allowlist_json(): cstring {.exportc, cdecl.} = zappFsAllowlistJson.cstring");
  expect(out).toContain("proc zapp_build_fs_persist_grants(): bool {.exportc, cdecl.} = true");
});

import { renderInitialWindowNim } from "./build-config";
test("renderInitialWindowNim emits empty getter when no window block", () => {
  const out = renderInitialWindowNim(undefined);
  expect(out).toContain("proc zapp_window_config_json*(): cstring");
  expect(out).toContain('"".cstring');
});

test("renderInitialWindowNim emits the window JSON (windowOptsApplyJson shape)", () => {
  const out = renderInitialWindowNim({
    title: "Kitchen Sink", width: 1100, height: 700,
    sidebar: { url: "#sidebar-pane", width: 240 },
    inspector: { url: "#inspector-pane", width: 300, collapsed: true },
  });
  expect(out).toContain("zapp_window_config_json");
  expect(out).toContain('\\"title\\":\\"Kitchen Sink\\"');
  expect(out).toContain('\\"sidebar\\":{\\"url\\":\\"#sidebar-pane\\"');
  expect(out).toContain('\\"inspector\\":');
  expect(out).toContain('\\"collapsed\\":true');
});
