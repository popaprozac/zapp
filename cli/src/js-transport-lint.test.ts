// Regression guard for review finding #2 (safe native->JS transport).
//
// Every native->JS delivery in the Nim layer must embed data via the ONE safe
// encoder (`jsLit` / `zapp_js_lit_dup`, native/shared/jslit.c). This test FAILS
// if any Nim source builds a dynamic `_onEvent(...)` / `_dispatchAppEvent(...)` /
// `_onInvokeResult(...)` / `_onWorkerMessage(...)` / `_resolveInvoke(...)` call
// with an interpolated (`& `) argument that is NOT wrapped in the encoder — i.e.
// a re-introduced string-injection hole.
//
// Scope: native/nim/*.nim only. The C side (zjs.c, windows/*.c) is guarded by
// its own build + the tracked windows-JS-hardening follow-up (see the Windows
// handoff doc); a C-side lint lands with that sweep.
import { test, expect } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";

const DIR = "native/nim";
const DELIVERY = /(_onEvent|_dispatchAppEvent|_onInvokeResult|_onWorkerMessage|_resolveInvoke)\s*\(/;
const ENCODER = /jsLit\(|zapp_js_lit_dup\(/;

test("no raw interpolation into native->JS delivery calls (finding #2 guard)", () => {
  const offenders: string[] = [];
  for (const f of readdirSync(DIR)) {
    if (!f.endsWith(".nim")) continue;
    if (f === "jslit.nim") continue; // the encoder module itself
    const lines = readFileSync(`${DIR}/${f}`, "utf8").split("\n");
    // Join Nim `&`-continued lines into one LOGICAL statement, so a delivery
    // call whose `jsLit(...)` argument sits on a continuation line is seen as
    // one unit (avoids false positives on the multi-line string builders).
    let i = 0;
    while (i < lines.length) {
      const startLine = i + 1;
      let stmt = lines[i];
      while (stmt.trimEnd().endsWith("&") && i + 1 < lines.length) {
        i++;
        stmt += " " + lines[i];
      }
      // A delivery call, with Nim string interpolation (`& `), whose whole
      // statement does NOT run its data through the one encoder = a re-introduced
      // hole. `%s`-template statements are the libc/`snprintf` path (worker.nim):
      // the `%s` args are filled by `zapp_js_lit_dup` via `snprintf` on adjacent
      // lines, so the `&` there only concatenates the template's string literals
      // — excluded here (guarded by review + the encoder-fill; a C-side data-flow
      // lint lands with the windows-JS-hardening follow-up).
      if (DELIVERY.test(stmt) && stmt.includes("& ") && !ENCODER.test(stmt) && !stmt.includes("%s")) {
        offenders.push(`${f}:${startLine}: ${stmt.trim().slice(0, 140)}`);
      }
      i++;
    }
  }
  expect(offenders, `raw native->JS interpolation (route through jsLit/zapp_js_lit_dup):\n${offenders.join("\n")}`).toEqual([]);
});
