import { NotesService } from "../bindings/znoteswails";
import { mountNotesApp } from "../../../../shared/app.js";
import "../../../../shared/app.css";

const benchmarkMode = await NotesService.BenchmarkMode();

await mountNotesApp({
  list: () => NotesService.List(),
  create: (input) => NotesService.Create(input),
}, benchmarkMode ? {
  enabled: true,
  iterations: 100,
  ready: () => NotesService.ReportBenchmark({ phase: "ready", payload: "" }),
  complete: (result) => NotesService.ReportBenchmark({
    phase: "complete",
    payload: JSON.stringify(result),
  }),
} : null);
