// Webview side of the host-bridge bench app. The actual benchmarks
// run inside three headless workers (one per engine, configured in
// zapp.config.ts); this page just listens for their result events
// and renders a status table.
//
// `run.sh` launches the app, captures stderr, and parses the bench
// CSV lines emitted by the workers — so the webview UI is
// scaffolding for human runs, not the data source.

import { Events, Window, WindowEvent } from "@zappdev/runtime";

const win = Window.current();
win.subscribe(WindowEvent.READY, () => win.show());

const out = document.getElementById("out") as HTMLDivElement;

interface BenchResult {
  engine: string;
  label: string;
  iters: number;
  totalMs: number;
  usPerOp: number;
}
const rows: Record<string, Record<string, BenchResult>> = {};

function render(): void {
  const engines = Object.keys(rows).sort();
  if (engines.length === 0) {
    out.textContent = "Waiting for bench workers...";
    return;
  }
  const labels = new Set<string>();
  for (const e of engines) {
    for (const l of Object.keys(rows[e])) labels.add(l);
  }
  const labelArr = Array.from(labels).sort();
  let html = `<table style="border-collapse:collapse"><thead><tr>` +
    `<th style="text-align:left;padding:4px 8px">engine</th>` +
    labelArr.map(l => `<th style="text-align:right;padding:4px 8px">${l} (µs/op)</th>`).join("") +
    `</tr></thead><tbody>`;
  for (const e of engines) {
    html += `<tr><td style="padding:4px 8px"><b>${e}</b></td>`;
    for (const l of labelArr) {
      const r = rows[e]?.[l];
      html += `<td style="padding:4px 8px;text-align:right">${r ? r.usPerOp.toFixed(2) : "—"}</td>`;
    }
    html += `</tr>`;
  }
  html += `</tbody></table>`;
  out.innerHTML = html;
}

Events.on("bench:result", (data: any) => {
  const r = data as BenchResult;
  rows[r.engine] = rows[r.engine] ?? {};
  rows[r.engine][r.label] = r;
  render();
});

render();
