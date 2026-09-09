// Observation metrics only. None represents compositor paint/presentation FPS.
export interface Frame { x: number; y: number; width: number; height: number }
export interface Sample {
  t: number; phase: number; source: string; nativeWidth: number; nativeHeight: number;
  domWidth: number; domHeight: number; pageTime: number;
}
export interface Leg {
  phase: number; frame: Frame; startedAt: number; duration: number; animating: boolean;
  isZoomed: boolean; animationWrites: number; displayCallbacks: number; skippedWrites: number;
}
export interface Report {
  instrumentationVersion: number; droppedSamples: number; mode: string; error: string | null;
  reduceMotion: boolean; maximumFramesPerSecond: number; backingScaleFactor: number; os: string;
  matchBackground: boolean; coordinateFrames: boolean;
  original: Frame; enlarged: Frame; final: Frame; closed: boolean; animationStopped: boolean;
  callbacksAfterClose: number; activeTimersAfterFinish: number; zoomRequests: number;
  legs: Leg[]; samples: Sample[];
}
export function sameFrame(left: Frame, right: Frame): boolean {
  return (["x", "y", "width", "height"] as const).every((key) =>
    Number.isFinite(left[key]) && Number.isFinite(right[key]) && Math.abs(left[key] - right[key]) <= 1);
}
export function percentile(values: number[], fraction: number): number | null {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.max(0, Math.ceil(sorted.length * fraction) - 1)]!;
}
export function summarizeLeg(report: Report, index: number) {
  const leg = report.legs[index]!;
  const samples = report.samples.filter((sample) => sample.phase === leg.phase);
  const nativeSizes = new Set(samples.map((sample) => `${Math.round(sample.nativeWidth)},${Math.round(sample.nativeHeight)}`)).size;
  const dom = samples.filter((sample) => sample.source === "dom");
  const domSizes = new Set(dom.map((sample) => `${sample.domWidth},${sample.domHeight}`)).size;
  // Sample at display callbacks inside the requested transition interval, not
  // during the 1-second settling period. These gaps INCLUDE DOM-message transit.
  const active = samples.filter((sample) => sample.source === "display" && sample.domWidth > 0 &&
    sample.t >= leg.startedAt && sample.t <= leg.startedAt + leg.duration);
  // AppKit's internal animation loop may let us observe only its initial frame.
  // No observed moving geometry means unavailable evidence, not zero lag.
  const activeSizes = new Set(active.map((sample) => `${sample.nativeWidth},${sample.nativeHeight}`));
  const observedWidthGapP95 = activeSizes.size > 1
    ? percentile(active.map((sample) => Math.abs(sample.nativeWidth - sample.domWidth)), 0.95) : null;
  const changes = dom.filter((sample, i) => i === 0 || sample.domWidth !== dom[i - 1]!.domWidth || sample.domHeight !== dom[i - 1]!.domHeight);
  const intervals = changes.slice(1).map((sample, i) => sample.pageTime - changes[i]!.pageTime);
  return {
    nativeSizes, domSizes, observationSamples: active.length, observedWidthGapP95,
    domChangeIntervalMedianMs: percentile(intervals, 0.5), durationMs: leg.duration * 1000,
    writes: leg.animationWrites - (report.legs[index - 1]?.animationWrites ?? 0),
    skippedWrites: leg.skippedWrites - (report.legs[index - 1]?.skippedWrites ?? 0),
  };
}
export function comparableConditions(left: Report, right: Report): boolean {
  return left.instrumentationVersion === right.instrumentationVersion &&
    left.os === right.os && left.backingScaleFactor === right.backingScaleFactor &&
    left.reduceMotion === right.reduceMotion && left.maximumFramesPerSecond === right.maximumFramesPerSecond &&
    sameFrame(left.original, right.original) && sameFrame(left.enlarged, right.enlarged) &&
    left.legs.length === right.legs.length && left.legs.every((leg, index) =>
      Math.abs(leg.duration - right.legs[index]!.duration) < 0.000001);
}
