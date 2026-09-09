// Native research only: no framework linkage, private window, bounded lifetime.
import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { runBoundedCommand } from "../../cli/src/bounded-process";

const modes = ["appkit-zoom", "delegate-zoom", "interrupted-zoom", "appkit-size", "stepped-size", "retarget-size", "close-size"] as const;
if (process.platform !== "darwin") throw new Error("The resize probe requires macOS 14+ and a visible desktop");
const selected = process.argv[2];
if (selected && !modes.includes(selected as typeof modes[number])) throw new Error(`Choose ${modes.join(", ")}`);
const repo = path.resolve(import.meta.dir, "../..");
const root = await mkdtemp(path.join(tmpdir(), "zapp-window-resize-"));
const output = path.join(repo, ".zapp/window-resize", path.basename(root) + ".json");

interface Frame { x: number; y: number; width: number; height: number }
interface Sample { t: number; phase: number; source: string; nativeWidth: number; nativeHeight: number; domWidth: number; domHeight: number }
interface Report {
  mode: string; error: string | null; reduceMotion: boolean; maximumFramesPerSecond: number;
  original: Frame; enlarged: Frame; final: Frame; closed: boolean; animationStopped: boolean;
  callbacksAfterClose: number; activeTimersAfterFinish: number; zoomRequests: number;
  legs: { phase: number; frame: Frame; animating: boolean; isZoomed: boolean; animationWrites: number; displayCallbacks: number }[];
  samples: Sample[];
}
function sameFrame(left: Frame, right: Frame) {
  return (Object.keys(left) as (keyof Frame)[]).every((key) => Math.abs(left[key] - right[key]) <= 1);
}
async function command(args: string[], timeoutMs: number) {
  const result = await runBoundedCommand(args, { cwd: root, timeoutMs });
  assert.equal(result.timedOut, false, `Timed out: ${args.join(" ")}`);
  assert.equal(result.status, 0, result.stderr || result.stdout || args.join(" "));
  return result;
}
const reports: Report[] = [];
try {
  const binary = path.join(root, "resize-probe");
  await command(["xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-O2", "-g",
    "-fsanitize=undefined", "-fno-sanitize-recover=all", "-mmacosx-version-min=14.0",
    "-framework", "AppKit", "-framework", "WebKit", "-framework", "QuartzCore",
    path.join(import.meta.dir, "probe.m"), "-o", binary], 60_000);
  await command(["codesign", "--force", "--sign", "-", binary], 15_000);
  for (const mode of selected ? [selected] : modes) {
    const result = await runBoundedCommand([binary, mode], { cwd: root, timeoutMs: 30_000 });
    assert.equal(result.timedOut, false, `Timed out: ${mode}`);
    assert.ok(result.stdout.trim(), result.stderr || `${mode} exited ${result.status} without observation data; check that a desktop is available`);
    const report: Report = JSON.parse(result.stdout);
    reports.push(report);
    assert.equal(result.status, 0, report.error || result.stderr || mode);
    assert.equal(report.error, null);
    assert.equal(report.animationStopped, true);
    assert.equal(report.callbacksAfterClose, 0);
    assert.equal(report.activeTimersAfterFinish, 0);
    assert.equal(report.legs.length, ["retarget-size", "close-size", "interrupted-zoom"].includes(mode) ? 1 : 2);
    assert.ok(report.legs.every((leg) => !leg.animating), "No animation may outlive its test leg");
    if (mode.endsWith("zoom")) assert.equal(report.zoomRequests, 2, "Both zoom requests must reach AppKit's delegate");
    assert.ok(report.samples.some((sample) => sample.source === "dom"), "WebView must report its viewport");
    const restored = sameFrame(report.final, report.original);
    if (["appkit-zoom", "appkit-size", "stepped-size", "retarget-size"].includes(mode)) {
      assert.ok(restored, `${mode} must restore the exact original frame`);
    }
    if (mode === "close-size") assert.equal(report.closed, true);
    if (["stepped-size", "appkit-size"].includes(mode)) {
      assert.ok(sameFrame(report.legs[0]!.frame, report.enlarged), `${mode} must reach its requested size`);
    }
    const changes = report.legs.map((leg) => {
      const samples = report.samples.filter((sample) => sample.phase === leg.phase);
      const dimensions = (key: "native" | "dom") => new Set(samples
        .filter((sample) => key === "native" || sample.source === "dom")
        .map((sample) => key === "native" ? `${Math.round(sample.nativeWidth)},${Math.round(sample.nativeHeight)}`
          : `${sample.domWidth},${sample.domHeight}`)).size;
      return `${dimensions("native")} native / ${dimensions("dom")} DOM sizes`;
    });
    console.log(`${mode}: ${changes.join("; ")}; restored=${restored}; screen max=${report.maximumFramesPerSecond} Hz; Reduce Motion=${report.reduceMotion}`);
    // Delegate zoom modes are experiments, not restoration gates: a lost
    // restore frame is evidence when choosing composition/native overrides.
  }
} finally {
  try {
    if (reports.length) {
      await mkdir(path.dirname(output), { recursive: true });
      await writeFile(output, JSON.stringify({ recordedAt: new Date().toISOString(), reports }, null, 2));
      console.log(`Observation data: ${output}`);
    }
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}
