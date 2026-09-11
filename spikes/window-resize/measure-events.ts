// Bounded actual-source measurement, not a paint/FPS or whole-application test.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { arch, cpus, release, tmpdir } from "node:os";
import { resolve } from "node:path";
import { runBoundedCommand } from "../../cli/src/bounded-process";
import { bundleWebviewBootstrapRaw } from "../../bootstrap/codegen";

const root = resolve(import.meta.dir, "../..");
const zRoot = resolve(root, "../z-lang");
const platform = resolve(root, "native/z/framework/platform/macos");
const compiler = process.env.ZAPP_Z_COMPILER ?? resolve(zRoot, ".z-cache/bootstrap/z");
const check = process.argv.includes("--check");
const sanitized = process.argv.includes("--ubsan");
const allocations = process.argv.includes("--allocations");
assert.equal(process.platform, "darwin");
assert(process.argv.slice(2).every((arg) => ["--check", "--ubsan", "--allocations"].includes(arg)), "Usage: measure-events.ts [--check] [--ubsan] [--allocations]");
const temporary = mkdtempSync(resolve(tmpdir(), "zapp-resize-events-"));

const hashes: Record<string, string> = {};
function source(path: string): string {
  const text = readFileSync(resolve(root, path), "utf8");
  hashes[path] = createHash("sha256").update(text).digest("hex");
  return text;
}
// Top-level declarations are anchored at column zero. Fail closed on drift;
// do not maintain a handwritten alternative serializer or event implementation.
function declaration(text: string, name: string): string {
  const pattern = new RegExp(`^(?:(?:internal|export|readonly) )*(?:function|struct|class) ${name}\\b`, "gm");
  const matches = [...text.matchAll(pattern)];
  assert.equal(matches.length, 1, `one production declaration: ${name}`);
  const start = matches[0]!.index!;
  const rest = text.slice(start);
  const end = rest.indexOf("\n}\n");
  assert(end > 0, `end of production declaration: ${name}`);
  return rest.slice(0, end + 3);
}
function replaceOnce(text: string, before: string, after: string): string {
  assert.equal(text.split(before).length, 2, `one instrumentation site: ${before}`);
  return text.replace(before, after);
}
async function command(args: string[], timeoutMs: number): Promise<string> {
  const result = await runBoundedCommand(args, { cwd: temporary, timeoutMs });
  assert(!result.timedOut, `timed out: ${args.join(" ")}\n${result.stdout}${result.stderr}`);
  assert.equal(result.status, 0, `${args.join(" ")}\n${result.stdout}${result.stderr}`);
  return result.stdout;
}

try {
  source("bootstrap/webview.ts");
  source("runtime/window-api.ts");
  source("spikes/window-resize/event-probe.h");
  const bootstrap = await bundleWebviewBootstrapRaw();
  const pageEntry = resolve(temporary, "page.ts");
  writeFileSync(pageEntry, `import { currentWindow, WindowEvent } from ${JSON.stringify(resolve(root, "runtime/window-api.ts"))};
globalThis[Symbol.for('zapp.windowId')]='probe-window';
const bridge=globalThis[Symbol.for('zapp.bridge')];const values=[];let calls=0;
let parseCalls=0,stringifyCalls=0;const parse=JSON.parse,stringify=JSON.stringify;
JSON.parse=(...a)=>{parseCalls++;return parse(...a)};
JSON.stringify=(...a)=>{stringifyCalls++;return stringify(...a)};
let batch=false;
currentWindow().subscribe(WindowEvent.RESIZE,e=>{if(!batch){calls++;values.push([e.windowId,e.size.width,e.size.height]);}});
// Amortize the WebView timer resolution; this is a synchronous JS-only batch,
// not IPC latency. Warm first, then reset all event/count observations.
batch=true;for(let i=0;i<1000;i++)bridge.dispatchWindowEvent('probe-window','resize','{"width":640,"height":440}');
const began=performance.now();for(let i=0;i<10000;i++)bridge.dispatchWindowEvent('probe-window','resize','{"width":640,"height":440}');
const jsBatchMeanUs=(performance.now()-began)*1000/10000;
batch=false;parseCalls=0;stringifyCalls=0;
globalThis.finishProbe=()=>{
  const report={calls,parseCalls,stringifyCalls,values,jsBatchMeanUs};
  webkit.messageHandlers.probe.postMessage('FRONTEND '+stringify(report));
};
addEventListener('error',e=>webkit.messageHandlers.probe.postMessage('ERROR '+e.message));
setTimeout(()=>{
  webkit.messageHandlers.probe.postMessage('ready');
  let step=0;const next=()=>{if(step++<6){webkit.messageHandlers.probe.postMessage('step');setTimeout(next,500)}else setTimeout(finishProbe,500)};
  setTimeout(next,100);
},100);`);
  const built = await Bun.build({ entrypoints: [pageEntry], target: "browser", minify: true });
  assert(built.success, built.logs.map(String).join("\n"));
  const frontend = await built.outputs[0]!.text();
  const page = `<!doctype html><style>body{background:#15212b;color:white}</style><h1>Resize event observation</h1><script>${bootstrap.replaceAll("</script", "<\\/script")}</script><script>${frontend.replaceAll("</script", "<\\/script")}</script>`;
  const events = source("native/z/framework/events.zs");
  const windowEvents = source("native/z/framework/window-events.zs").replace(/^import[^;]+;\s*/gm, "");
  const delivery = source("native/z/framework/platform/macos/response-delivery.zs");
  const serializer = ["WebViewWindowEventEnvelope", "WebViewWindowSizePayload", "javascriptJSON", "windowEventScript"]
    .map((name) => declaration(delivery, name)).join("\n");
  let deliverResize = declaration(delivery, "deliverWebViewWindowResize");
  deliverResize = replaceOnce(deliverResize, "  const payload =", "  probe.probe_begin(2);\n  const payload =");
  deliverResize = replaceOnce(deliverResize, "  webView.evaluateJavaScript(", "  probe.probe_end();\n  const index = probe.probe_sent(script.byteLength, width, height);\n  probe.probe_begin(3);\n  webView.evaluateJavaScript(");
  deliverResize = replaceOnce(deliverResize, "completionHandler: move (value, error): void => {}", "completionHandler: move (value, error): void => { probe.probe_completed(index, error == null); }");
  deliverResize = replaceOnce(deliverResize, "  );\n}", "  );\n  probe.probe_end();\n}");
  const controller = source("native/z/framework/platform/macos/window-resize.zs")
    .replace('import { thread } from "std/thread";', "")
    .replaceAll("WebKit.NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion", "false")
    .replace(/const duration = super\.animationResizeTime\((frame|target)\);/g, "const duration: f64 = 0.25;");
  const input = `${events}\n${windowEvents}\n${controller}\nimport json from "std/json";\nimport { TextBuffer } from "std/text";\n${serializer}\n${deliverResize}\nfunction probePage(): String { return ${JSON.stringify(page)}; }\n${source("spikes/window-resize/event-probe.zs.in")}`;
  writeFileSync(resolve(temporary, "main.zs"), input);
  writeFileSync(resolve(temporary, "z.json"), JSON.stringify({ package: { name: "zapp-event-probe", version: "0.0.0" }, target: { name: "event-probe", entry: "main.zs", platform: "macos", minimumVersion: "14.0" } }));
  symlinkSync(resolve(platform, "WebKit.h.zd"), resolve(temporary, "WebKit.h.zd"));
  symlinkSync(resolve(import.meta.dir, "event-probe.h"), resolve(temporary, "event-probe.h"));
  const emitted = await command([compiler, "emit", resolve(temporary, "main.zs")], 120_000);
  // Count generated allocation requests in a separate, timing-perturbing pass.
  // Clang may still eliminate the backing allocation (not its counter), e.g.
  // with no listeners. These are not libc heap/peak-memory measurements.
  // Normal timings leave emitted allocation calls untouched.
  const generated = '#include "event-probe.h"\n' + (allocations ? emitted.replace(/\b(malloc|calloc|realloc)\(/g, "probe_$1(") : emitted);
  writeFileSync(resolve(temporary, "main.m"), generated);
  const flags = ["-O2", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-mmacosx-version-min=14.0"];
  if (sanitized) flags.push("-fsanitize=undefined", "-fno-sanitize-recover=all");
  if (check) {
    await command(["xcrun", "clang", ...flags, "-fsyntax-only", resolve(temporary, "main.m")], 60_000);
    console.log("Actual-source resize-event probe checked; no window opened.");
  } else {
    const binary = resolve(temporary, "probe");
    await command(["xcrun", "clang", ...flags, "-framework", "AppKit", "-framework", "QuartzCore", "-framework", "WebKit", resolve(temporary, "main.m"), "-o", binary], 60_000);
    const runs = [];
    for (let run = 0; run < 3; run++) {
      const output = await command([binary], 15_000);
      const lines = output.trim().split("\n");
      const frontend = JSON.parse(lines.find((line) => line.startsWith("FRONTEND "))!.slice(9));
      const delivery = JSON.parse(lines.find((line) => line.startsWith("DELIVERY "))!.slice(9));
      const metrics = lines.filter((line) => line.startsWith("METRIC ")).map((line) => JSON.parse(line.slice(7)));
      for (const metric of metrics) {
        if (!allocations || metric.stage === "webKitCompletion") metric.allocationCalls = null;
      }
      const expected = JSON.parse(lines.find((line) => line.startsWith("EXPECTED "))!.slice(9));
      assert.deepEqual(frontend.values, expected, "ordered identities and dimensions survive the complete delivery path");
      assert.equal(frontend.calls, delivery.sent, "one frontend event per native notification");
      assert.equal(delivery.completed, delivery.sent);
      assert(frontend.values.every((value: unknown[]) => value[0] === "probe-window"));
      const duplicates = frontend.values.slice(1).filter((value: unknown[], i: number) => JSON.stringify(value) === JSON.stringify(frontend.values[i])).length;
      runs.push({ metrics, delivery, frontend, consecutiveDuplicateSizes: duplicates });
      console.log(JSON.stringify({ run: run + 1, metrics, delivery, frontendCalls: frontend.calls, parseCalls: frontend.parseCalls, stringifyCalls: frontend.stringifyCalls, jsBatchMeanUs: frontend.jsBatchMeanUs, consecutiveDuplicateSizes: duplicates }, null, 2));
    }
    const directory = resolve(root, ".zapp/window-resize");
    mkdirSync(directory, { recursive: true });
    const report = resolve(directory, `events-${Date.now()}.json`);
    writeFileSync(report, JSON.stringify({ version: 3, sanitized, allocations, compiler,
      emittedHash: createHash("sha256").update(emitted).digest("hex"),
      host: { arch: arch(), release: release(), cpu: cpus()[0]?.model }, hashes, runs }, null, 2));
    console.log(`Saved ${report}`);
  }
} finally {
  if (process.env.ZAPP_KEEP_RESIZE_PROBE === "1") console.log(`Kept ${temporary}`);
  else rmSync(temporary, { recursive: true, force: true });
}
