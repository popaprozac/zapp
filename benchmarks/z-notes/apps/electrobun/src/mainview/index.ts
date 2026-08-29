import Electrobun, { Electroview } from "electrobun/view";
import { mountNotesApp } from "../../../../shared/app.js";
import "../../../../shared/app.css";
import type { NotesRPC } from "../shared/schema";

const rpc = Electroview.defineRPC<NotesRPC>({
  maxRequestTime: 5_000,
  handlers: { requests: {}, messages: {} },
});
const electrobun = new Electrobun.Electroview({ rpc });
const benchmarkMode = await electrobun.rpc!.request.benchmarkMode({});

await mountNotesApp({
  list: () => electrobun.rpc!.request.list({}),
  create: (input) => electrobun.rpc!.request.create(input),
}, benchmarkMode ? {
  enabled: true,
  iterations: 100,
  ready: () => electrobun.rpc!.request.reportBenchmark({ phase: "ready", payload: "" }),
  complete: (result) => electrobun.rpc!.request.reportBenchmark({
    phase: "complete",
    payload: JSON.stringify(result),
  }),
} : null);
