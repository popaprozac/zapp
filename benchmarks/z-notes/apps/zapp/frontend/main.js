import { mountNotesApp } from "../../../shared/app.js";
import "../../../shared/app.css";

const notes = globalThis.__zappServices.notes;
const benchmarkMode = await notes.benchmarkMode();

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
  complete: (result) => notes.reportBenchmark({
    phase: "complete",
    payload: JSON.stringify(result),
  }),
} : null);
