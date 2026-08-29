import { invoke } from "@tauri-apps/api/core";
import { mountNotesApp } from "../../../shared/app.js";
import "../../../shared/app.css";

const benchmarkMode = await invoke("benchmark_mode");

await mountNotesApp({
  list: () => invoke("list_notes"),
  create: (input) => invoke("create_note", { input }),
}, benchmarkMode ? {
  enabled: true,
  iterations: 100,
  ready: () => invoke("report_benchmark", {
    report: { phase: "ready", payload: "" },
  }),
  complete: (result) => invoke("report_benchmark", {
    report: { phase: "complete", payload: JSON.stringify(result) },
  }),
} : null);
