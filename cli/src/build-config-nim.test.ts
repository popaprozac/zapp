import { test, expect } from "bun:test";
import { renderBuildConfigNim } from "./build-config";

test("renderBuildConfigNim emits exportc getters the .m layer calls", () => {
  const out = renderBuildConfigNim({
    initialUrl: "zapp://index.html",
    identifier: "com.example.app",
    name: "Example App",
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
  // App name getter (drives the Nim build's newApp / menu name).
  expect(out).toContain('proc zapp_build_name(): cstring {.exportc, cdecl.} = zappName.cstring');
  expect(out).toContain('let zappName = "Example App"');
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
    "bench-zjs": { script: "src/bench-worker.ts", name: "bench", engine: "zjs" },
    "bench-bare-jsc": { script: "src/bench-worker.ts", engine: "bare-jsc" },
  });
  // zjs entry → registry registration (engine 7 + display name) THEN spawn,
  // both keyed by h-<id> (matches the .zc zapp_start_headless_worker_full path).
  expect(out).toContain(
    'discard zapp_worker_registry_add_full_with_engine_and_name(cstring"h-bench-zjs", cstring"", cstring"/_workers/_headless_bench-zjs.mjs", cint(7), cstring"bench")',
  );
  expect(out).toContain(
    'discard zjs_worker_create(cstring"/_workers/_headless_bench-zjs.mjs", cstring"", cstring"h-bench-zjs")',
  );
  // non-zjs entry → neither registration nor spawn.
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
    name: "Example App",
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
    name: "Test App",
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

import { buildPermissionsManifest } from "./native";
test("buildPermissionsManifest derives platform from the build target (ios vs macos)", () => {
  const resolved = { active: true, allow: ["clipboard"] };
  // iOS targets → platform:"ios" (not the hardcoded macos).
  expect(buildPermissionsManifest("ios-simulator", resolved).platform).toBe("ios");
  expect(buildPermissionsManifest("ios-device", resolved).platform).toBe("ios");
  // Everything else → platform:"macos" (today's behavior preserved).
  expect(buildPermissionsManifest("macos", resolved).platform).toBe("macos");
  // active/allow are passed through untouched.
  const ios = buildPermissionsManifest("ios-simulator", resolved);
  expect(ios.active).toBe(true);
  expect(ios.allow).toEqual(["clipboard"]);
});

import { renderNimCfg } from "./build-config";
test("renderNimCfg emits absolute --path lines, fidelity flags, and a do-not-edit header", () => {
  const out = renderNimCfg({
    frameworkNimDir: "/abs/native/nim",
    zappDir: "/abs/project/.zapp",
  });
  expect(out).toContain('--path:"/abs/native/nim"');
  expect(out).toContain('--path:"/abs/project/.zapp"');
  expect(out).toContain("--mm:orc");
  expect(out).toContain("--threads:on");
  expect(out.toLowerCase()).toContain("do not edit");
  // Escape hatch is advertised so power users don't fight the generator.
  expect(out).toContain("app.nim.cfg");
});

test("renderNimCfg normalizes backslashes so Windows paths are benign in the cfg", () => {
  const out = renderNimCfg({
    frameworkNimDir: "C:\\app\\native\\nim",
    zappDir: "C:\\app\\.zapp",
  });
  expect(out).toContain('--path:"C:/app/native/nim"');
  expect(out).toContain('--path:"C:/app/.zapp"');
});
