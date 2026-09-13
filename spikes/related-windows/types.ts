// Result records from the isolated Objective-C/WebKit benchmark host.
export type BenchmarkMode = "related" | "related-root" | "independent";
export interface Samples {
  samples: { elapsedMs: number; localCommitMs: number }[];
  wallMs: number;
  count: number;
  meanCompletionMs: number;
  logicalChangesPerCommit: number;
}
export interface BenchmarkResult {
  kind: "result";
  pass: boolean;
  mode: BenchmarkMode;
  origin: "http:" | "zapp:";
  react: string;
  ownerScriptLoadInitMs: number;
  startup: {
    readyMs: number;
    twoFramesMs: number;
    scriptLoadInitMs: number;
    frameworkLoadedHere: boolean;
    directOpener: boolean;
  }[];
  nativeCreationMs: number[];
  delta: Samples;
  coalesced32: Samples;
  frames: Samples;
  createdChildren: number;
  closedChildren: number;
  totalUpdates: number;
  relayCount: number;
  relayBytes: number;
}
export interface RecordedBenchmark extends BenchmarkResult {
  round: number;
  processMs: number;
  stderr: string;
}
