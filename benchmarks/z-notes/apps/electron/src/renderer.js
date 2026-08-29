import { mountNotesApp } from "./shared/app.js";

const benchmarkMode = await globalThis.zNotes.benchmarkMode();

await mountNotesApp({
  list: () => globalThis.zNotes.list(),
  create: (input) => globalThis.zNotes.create(input),
}, benchmarkMode ? {
  enabled: true,
  iterations: 100,
  ready: () => globalThis.zNotes.reportBenchmark({
    phase: "ready",
    payload: "",
  }),
  complete: (result) => globalThis.zNotes.reportBenchmark({
    phase: "complete",
    payload: JSON.stringify(result),
  }),
} : null);
