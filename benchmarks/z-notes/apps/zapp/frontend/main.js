import { mountNotesApp } from "../../../shared/app.js";
import "../../../shared/app.css";
import { notes } from "zapp:services";

const benchmarkMode = await notes.benchmarkMode();

async function measureBridgeProbe(iterations, operation) {
  const started = performance.now();
  for (let index = 0; index < iterations; index += 1) {
    await operation(index);
  }
  return {
    iterations,
    durationMs: performance.now() - started,
  };
}

await mountNotesApp({
  async list() {
    const page = await notes.list();
    return page.notes;
  },
  async create(input) {
    const note = await notes.create(input);
    return { ...note, id: note.id.toString() };
  },
}, benchmarkMode ? {
  enabled: true,
  iterations: 100,
  ready: () => notes.reportBenchmark({ phase: "ready", payload: "" }),
  async probe() {
    const iterations = 1000;
    return {
      noop: await measureBridgeProbe(iterations, () => notes.benchmarkNoop()),
      typedEcho: await measureBridgeProbe(iterations, (sequence) => notes.benchmarkEcho({
        sequence,
        label: "Zapp bridge probe",
        active: true,
      })),
    };
  },
  complete: (result) => notes.reportBenchmark({
    phase: "complete",
    payload: JSON.stringify(result),
  }),
} : null);
