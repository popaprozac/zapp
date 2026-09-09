// Native research only: no framework linkage, private window, bounded lifetime.
import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { runBoundedCommand } from "../../cli/src/bounded-process";
import { comparableConditions, sameFrame, summarizeLeg, type Report } from "./metrics";

const comparisons = ["stepped-size", "background-size", "coordinated-size", "combined-size"];
const modes = ["appkit-zoom", "delegate-zoom", "interrupted-zoom", "appkit-size", ...comparisons, "retarget-size", "close-size"];
if (process.platform !== "darwin") throw new Error("The resize probe requires macOS 14+ and a visible desktop");
const selected = process.argv[2];
if (selected && selected !== "compare" && !modes.includes(selected)) throw new Error(`Choose compare or ${modes.join(", ")}`);
const flags = process.argv.slice(3);
if (flags.length && (flags.length !== 2 || flags[0] !== "--repeat" || !/^[1-5]$/.test(flags[1]!))) {
  throw new Error("usage: bun run spikes/window-resize/run.ts [compare|mode] [--repeat 1..5]");
}
const repetitions = flags.length ? Number(flags[1]) : 1;
const repo = path.resolve(import.meta.dir, "../..");
const root = await mkdtemp(path.join(tmpdir(), "zapp-window-resize-"));
const output = path.join(repo, ".zapp/window-resize", path.basename(root) + ".json");

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
  const chosen = selected === "compare" ? comparisons : selected ? [selected] : modes;
  // Rotate the starting mode so every repeat does not give one candidate the
  // same WebKit startup/cache/system-load position. This is not randomization.
  const schedule = Array.from({ length: repetitions }, (_, round) => {
    const offset = round % chosen.length;
    return [...chosen.slice(offset), ...chosen.slice(0, offset)].map((mode) => ({ mode, round }));
  }).flat();
  for (const { mode, round } of schedule) {
    const result = await runBoundedCommand([binary, mode], { cwd: root, timeoutMs: 30_000 });
    assert.equal(result.timedOut, false, `Timed out: ${mode}`);
    assert.ok(result.stdout.trim(), result.stderr || `${mode} exited ${result.status} without observation data; check that a desktop is available`);
    const report: Report = JSON.parse(result.stdout);
    reports.push(report);
    assert.equal(result.status, 0, report.error || result.stderr || mode);
    assert.equal(report.error, null);
    assert.equal(report.instrumentationVersion, 2);
    assert.equal(report.droppedSamples, 0);
    assert.equal(report.matchBackground, ["background-size", "combined-size"].includes(mode));
    assert.equal(report.coordinateFrames, ["coordinated-size", "combined-size"].includes(mode));
    assert.equal(report.animationStopped, true);
    assert.equal(report.callbacksAfterClose, 0);
    assert.equal(report.activeTimersAfterFinish, 0);
    assert.equal(report.legs.length, ["retarget-size", "close-size", "interrupted-zoom"].includes(mode) ? 1 : 2);
    assert.ok(report.legs.every((leg) => !leg.animating), "No animation may outlive its test leg");
    if (mode.endsWith("zoom")) assert.equal(report.zoomRequests, 2, "Both zoom requests must reach AppKit's delegate");
    assert.ok(report.samples.some((sample) => sample.source === "dom"), "WebView must report its viewport");
    const restored = sameFrame(report.final, report.original);
    if (["appkit-zoom", "appkit-size", ...comparisons, "retarget-size"].includes(mode)) {
      assert.ok(restored, `${mode} must restore the exact original frame`);
    }
    if (mode === "close-size") assert.equal(report.closed, true);
    if ([...comparisons, "appkit-size"].includes(mode)) {
      assert.ok(sameFrame(report.legs[0]!.frame, report.enlarged), `${mode} must reach its requested size`);
    }
    const changes = report.legs.map((_, index) => {
      const metrics = summarizeLeg(report, index);
      return `${metrics.nativeSizes} native / ${metrics.domSizes} DOM sizes, ${metrics.writes} writes (${metrics.skippedWrites} skipped), observed width gap p95=${metrics.observedWidthGapP95?.toFixed(1) ?? "n/a"}pt, duration=${metrics.durationMs.toFixed(1)}ms`;
    });
    console.log(`${round + 1}/${repetitions} ${mode}: ${changes.join("; ")}; restored=${restored}; screen max=${report.maximumFramesPerSecond} Hz; Reduce Motion=${report.reduceMotion}`);
    // Delegate zoom modes are experiments, not restoration gates: a lost
    // restore frame is evidence when choosing composition/native overrides.
  }
  if (selected === "compare") {
    assert.ok(reports.every((report) => comparableConditions(reports[0]!, report)),
      "Comparison conditions changed: inspect the saved data rather than claiming a timing win");
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
