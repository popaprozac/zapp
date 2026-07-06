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

import { renderPlatformNim } from "./build-config";
import { resolveNativeDir } from "./paths";

test("renderPlatformNim (macos) reproduces today's darwin pragmas", () => {
  const nativeDir = resolveNativeDir();
  const out = renderPlatformNim("macos", { nativeDir });
  // Per-file CALL form (NOT the tuple form) with -fobjc-arc for each darwin .m.
  // The compile paths are ABSOLUTE (CLI-resolved from nativeDir): the generated
  // module lives in the project's .zapp/, where a relative ../platform/darwin/*
  // would resolve to <project>/platform/darwin/* (wrong dir) and break the build.
  // The spike confirmed both relative-to-module and absolute compile paths work;
  // absolute is correct here because the .m sources live in the FRAMEWORK's
  // native/, not the project. End-of-path is the darwin/<file>.m signature.
  expect(out).toMatch(/\{\.compile\("\/.*\/platform\/darwin\/platform\.m", "-fobjc-arc"\)\.\}/);
  expect(out).toMatch(/\{\.compile\("\/.*\/platform\/darwin\/window\.m", "-fobjc-arc"\)\.\}/);
  expect(out).toMatch(/\{\.compile\("\/.*\/platform\/darwin\/webview\.m", "-fobjc-arc"\)\.\}/);
  expect(out).toMatch(/\{\.compile\("\/.*\/platform\/darwin\/sync\.m", "-fobjc-arc"\)\.\}/);
  // clipboard.m is now owned HERE (target-correct via getPlatformSources), not
  // clipboard.nim — on macOS that's darwin/clipboard.m. clipboard.nim dropped its
  // own `{.compile.}`, so only one source compiles it (no duplicate symbols).
  expect(out).toMatch(/\{\.compile\("\/.*\/platform\/darwin\/clipboard\.m", "-fobjc-arc"\)\.\}/);
  // NO ios sources in the macOS branch.
  expect(out).not.toContain("/platform/ios/");
  // Full macOS framework set (current zapp.nim line 12), verbatim.
  expect(out).toContain("-framework Cocoa");
  expect(out).toContain("-framework Carbon");
  expect(out).toContain("-framework WebKit");
  expect(out).toContain("-framework CoreFoundation");
  expect(out).toContain("-framework JavaScriptCore");
  expect(out).toContain("-framework Security");
  expect(out).toContain("-framework IOKit");
  expect(out).toContain("-framework ServiceManagement");
  expect(out).toContain("-framework UserNotifications");
  expect(out).toContain("-framework Foundation");
  // NO UIKit on macOS.
  expect(out).not.toContain("-framework UIKit");
  // libcompression + STATIC libzjs_embed.a (macOS link surface). The Nim path
  // links the symbol-hidden repack — NOT the dylib — so a packaged .app is
  // standalone by construction (no dylib to bundle, no -rpath to rewrite).
  expect(out).toContain("-lcompression");
  expect(out).toContain("vendor/zjs/build/libzjs_embed.a");
  expect(out).not.toContain("libzjs.dylib");
  expect(out).not.toContain("-Wl,-rpath,");
  // libzjs_embed.a path is ABSOLUTE (CLI-resolved), not currentSourcePath-relative.
  expect(out).toMatch(/\{\.passL: "\/.*vendor\/zjs\/build\/libzjs_embed\.a"\.\}/);
  // -lz (zlib) is now required on macOS too: static-linking libzjs leaves
  // host_zlib_codec's deflate/inflate undefined (the old dylib carried its own).
  expect(out).toContain("-lz");
});

test("renderPlatformNim (ios-simulator) emits ios sources + UIKit + libzjs_embed.a", () => {
  const nativeDir = resolveNativeDir();
  const out = renderPlatformNim("ios-simulator", { nativeDir });
  // iOS .m sources via the call form (ABSOLUTE path, same reasoning as macOS).
  expect(out).toMatch(/\{\.compile\("\/.*\/platform\/ios\/platform\.m", "-fobjc-arc"\)\.\}/);
  expect(out).toMatch(/\{\.compile\("\/.*\/platform\/ios\/window\.m", "-fobjc-arc"\)\.\}/);
  expect(out).toMatch(/\{\.compile\("\/.*\/platform\/ios\/webview\.m", "-fobjc-arc"\)\.\}/);
  // clipboard.m owned HERE on iOS too — ios/clipboard.m (UIPasteboard), NOT the
  // darwin one. clipboard.nim no longer compiles a hardcoded darwin/clipboard.m.
  expect(out).toMatch(/\{\.compile\("\/.*\/platform\/ios\/clipboard\.m", "-fobjc-arc"\)\.\}/);
  // NO darwin sources in the iOS branch.
  expect(out).not.toContain("/platform/darwin/");
  // iOS framework set (UIKit replaces Cocoa; no Carbon).
  expect(out).toContain("-framework UIKit");
  expect(out).toContain("-framework Foundation");
  expect(out).toContain("-framework WebKit");
  expect(out).toContain("-framework JavaScriptCore");
  expect(out).toContain("-framework UserNotifications");
  expect(out).toContain("-framework UniformTypeIdentifiers");
  expect(out).toContain("-framework Security");
  expect(out).not.toContain("-framework Cocoa");
  expect(out).not.toContain("-framework Carbon");
  // libs: -lcompression + -lz (zlib, iOS SDK).
  expect(out).toContain("-lcompression");
  expect(out).toContain("-lz");
  // Static libzjs_embed.a for the simulator-arm64 slice; NO dylib, NO rpath.
  expect(out).toContain("vendor/zjs/build/ios/simulator-arm64/libzjs_embed.a");
  expect(out).not.toContain("libzjs.dylib");
  expect(out).not.toContain("-Wl,-rpath,");
});

test("renderPlatformNim (macos) CEF gate: system output is byte-identical; chromium APPENDS the CEF block", () => {
  const nativeDir = resolveNativeDir();
  // GATE: no cef → the WKWebView path → BYTE-IDENTICAL to the no-arg macOS
  // output. This is the guarantee that a webEngine:"system" build does zero
  // CEF work and its compile/link surface never changes.
  const system = renderPlatformNim("macos", { nativeDir });
  const systemAgain = renderPlatformNim("macos", { nativeDir, cef: undefined });
  expect(systemAgain).toBe(system);
  expect(system).not.toContain("chromium (CEF)");
  expect(system).not.toContain("zapp_cef_");

  // chromium → the SAME system bytes, then the CEF pragmas appended verbatim.
  const cef = renderPlatformNim("macos", { nativeDir, cef: { root: "/CEFROOT" } });
  expect(cef.startsWith(system)).toBe(true); // system prefix unchanged
  const appended = cef.slice(system.length);
  // Five main-exe sources (c11 glue + ARC ObjC); mac_helper.c/bridge.c are
  // Helper-only and MUST NOT appear here. (Compile paths are the framework's
  // native/platform/darwin/cef dir, not the CEF root.)
  expect(appended).toContain("platform/darwin/cef/zapp_cef_app.c");
  expect(appended).toContain("zapp_cef_app.c\", \"-std=c11\"");
  expect(appended).toContain("zapp_cef_client.c\", \"-std=c11\"");
  expect(appended).toContain("zapp_cef_scheme_handler.c\", \"-std=c11\"");
  expect(appended).toContain("zapp_cef_mac_entry.m\", \"-fobjc-arc\"");
  expect(appended).toContain("zapp_cef_host.m\", \"-fobjc-arc\"");
  expect(appended).not.toContain("zapp_cef_mac_helper.c");
  expect(appended).not.toContain("zapp_cef_bridge.c");
  // Includes + framework link + -lcompression + rpath.
  expect(appended).toContain('{.passC: "-I/CEFROOT".}');
  expect(appended).toContain("Chromium Embedded Framework.framework/Chromium Embedded Framework'");
  expect(appended).toContain("-lcompression");
  expect(appended).toContain("-Wl,-rpath,@executable_path/../Frameworks");
});

// chromium never affects a non-macOS target (macOS-only production slice): even
// when a cef root is threaded through, the iOS output stays byte-identical.
test("renderPlatformNim (ios-simulator) ignores cef (macOS-only slice)", () => {
  const nativeDir = resolveNativeDir();
  const plain = renderPlatformNim("ios-simulator", { nativeDir });
  const withCef = renderPlatformNim("ios-simulator", { nativeDir, cef: { root: "/CEFROOT" } });
  expect(withCef).toBe(plain);
  expect(withCef).not.toContain("zapp_cef_");
});

import { generateIOSBuildFile } from "./build-config";
import { mkdtemp, writeFile, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";

test("generateIOSBuildFile: no engine named → defaults to zjs, NOT bare-jsc", async () => {
  // A fresh app with no workers / no engine must not trigger a Bare-from-source
  // build on iOS. zjs.c is always linked in the Nim build, so zjs is the correct
  // zero-extra-build default; bare is opt-in only (named explicitly).
  const dir = await mkdtemp(`${tmpdir()}/zapp-ios-engine-`);
  try {
    const buildFile = `${dir}/build.zc`;
    await writeFile(buildFile, 'import "app.zc";\nfn main() -> int { return run_app(); }\n');
    const outPath = await generateIOSBuildFile(dir, buildFile, undefined);
    const out = await readFile(outPath, "utf-8");
    expect(out).toContain("//> define: ZAPP_WORKER_ENGINE_ZJS");
    expect(out).not.toContain("ZAPP_WORKER_ENGINE_BARE_JSC");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("generateIOSBuildFile: explicitly-named bare-jsc is still honored", async () => {
  // Bare stays available when the app opts in (future worker-flexibility spike).
  const dir = await mkdtemp(`${tmpdir()}/zapp-ios-engine-`);
  try {
    const buildFile = `${dir}/build.zc`;
    await writeFile(buildFile, 'import "app.zc";\n');
    const cfg = { headless: { w: { script: "a.ts", engine: "bare-jsc" } } } as any;
    const outPath = await generateIOSBuildFile(dir, buildFile, cfg);
    const out = await readFile(outPath, "utf-8");
    expect(out).toContain("//> define: ZAPP_WORKER_ENGINE_BARE_JSC");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
