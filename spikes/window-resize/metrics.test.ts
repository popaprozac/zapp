import { describe, expect, it } from "bun:test";
import { comparableConditions, percentile, sameFrame, summarizeLeg, type Report, type Sample } from "./metrics";

const frame = { x: 0, y: 0, width: 600, height: 400 };
function sample(t: number, nativeWidth: number, domWidth: number, source = "display", pageTime = t * 1000): Sample {
  return { t, nativeWidth, domWidth, source, pageTime, phase: 1, nativeHeight: 400, domHeight: 400 };
}
function report(): Report {
  return {
    mode: "stepped-size", instrumentationVersion: 2, droppedSamples: 0, error: null,
    reduceMotion: false, maximumFramesPerSecond: 120, backingScaleFactor: 2, os: "fixture",
    matchBackground: false, coordinateFrames: false,
    original: frame, enlarged: { ...frame, width: 900 }, final: frame, closed: false, animationStopped: true,
    callbacksAfterClose: 0, activeTimersAfterFinish: 0, zoomRequests: 0,
    legs: [{ phase: 1, frame, startedAt: 1, duration: 0.4, animating: false,
      isZoomed: false, animationWrites: 12, displayCallbacks: 30, skippedWrites: 2 }], samples: [],
  };
}
describe("resize observation metrics", () => {
  it("checks every geometry component and rejects nonfinite values", () => {
    expect(sameFrame(frame, { ...frame, x: 0.5 })).toBe(true);
    expect(sameFrame(frame, { ...frame, height: 402 })).toBe(false);
    expect(sameFrame(frame, { ...frame, width: NaN })).toBe(false);
  });
  it("uses a nearest-rank percentile without mutating observations", () => {
    const values = [40, 10, 30, 20];
    expect(percentile(values, 0.5)).toBe(20);
    expect(percentile(values, 0.95)).toBe(40);
    expect(percentile([], 0.5)).toBeNull();
    expect(values).toEqual([40, 10, 30, 20]);
  });
  it("excludes readiness, uninitialized DOM values, and settled samples from gap measurements", () => {
    const value = report();
    value.samples = [sample(0.9, 900, 600), sample(1.05, 800, 0),
      sample(1.1, 800, 750), sample(1.2, 850, 825), sample(1.5, 900, 900)];
    const summary = summarizeLeg(value, 0);
    expect(summary.observationSamples).toBe(2);
    expect(summary.observedWidthGapP95).toBe(50);
  });
  it("uses page-clock intervals and ignores unchanged viewport heartbeats", () => {
    const value = report();
    value.samples = [sample(1, 650, 600, "dom", 10), sample(1.2, 700, 600, "dom", 20),
      sample(1.21, 750, 700, "dom", 30), sample(1.3, 800, 750, "dom", 50)];
    expect(summarizeLeg(value, 0).domChangeIntervalMedianMs).toBe(20);
    expect(summarizeLeg(value, 0).domSizes).toBe(3);
  });
  it("reports per-leg rather than cumulative writes", () => {
    const value = report();
    value.legs.push({ ...value.legs[0]!, phase: 2, animationWrites: 20, skippedWrites: 3 });
    expect(summarizeLeg(value, 1).writes).toBe(8);
    expect(summarizeLeg(value, 1).skippedWrites).toBe(1);
  });
  it("does not invent timing evidence when reduced motion has no active samples", () => {
    const value = report();
    value.reduceMotion = true;
    value.legs[0]!.duration = 0;
    value.samples = [sample(1.1, 900, 900)];
    expect(summarizeLeg(value, 0).observedWidthGapP95).toBeNull();
    expect(summarizeLeg(value, 0).domChangeIntervalMedianMs).toBeNull();
  });
  it("does not report zero lag when AppKit prevents observing moving frames", () => {
    const emptyMotion = report();
    emptyMotion.samples = [sample(1.01, 600, 600), sample(1.02, 600, 600), sample(1.5, 900, 900)];
    expect(summarizeLeg(emptyMotion, 0).observedWidthGapP95).toBeNull();
  });
  it("refuses to compare different durations, displays, geometry, or instrumentation", () => {
    const first = report();
    for (const alter of [
      (value: Report) => { value.legs[0]!.duration = 0.5; },
      (value: Report) => { value.maximumFramesPerSecond = 60; },
      (value: Report) => { value.backingScaleFactor = 1; },
      (value: Report) => { value.os = "another release"; },
      (value: Report) => { value.original = { ...frame, width: 700 }; },
      (value: Report) => { value.instrumentationVersion = 1; },
      (value: Report) => { value.reduceMotion = true; },
    ]) {
      const second = report(); alter(second);
      expect(comparableConditions(first, second)).toBe(false);
    }
    expect(comparableConditions(first, report())).toBe(true);
  });
});
