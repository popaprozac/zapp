// cef-hello — the render+bridge smoke target for the CEF `webEngine:"chromium"`
// production slice. One button, one service call: click → `greet` round-trips
// through Services.invoke (webview → Nim router → back), same bridge path
// WKWebView uses today, on whatever engine `zapp.config.ts`'s `webEngine`
// resolves to.
import { Events, Services, Window } from "@zappdev/runtime";

const goButton = document.querySelector<HTMLButtonElement>("#go")!;
const out = document.querySelector<HTMLPreElement>("#out")!;
const tick = document.querySelector<HTMLPreElement>("#tick")!;
const which = document.querySelector<HTMLPreElement>("#which")!;

// Sub-cycle B: the page is shared by both CEF windows (same bundle), so the
// ONE thing that differs per-window at the JS layer is the native windowId
// carrier (Symbol.for('zapp.windowId'), injected per-browser at doc-start —
// see zapp_cef_host.m's bootstrap builder). Rendering it here is the visual
// proof (alongside the title bar) that each window has its OWN bridge/router
// identity, not a shared one.
which.textContent = `window: ${Window.current().id}`;

// Sub-cycle A gate: the ticker worker broadcasts `tick` every second; render it.
// If this increments on a chromium build, the worker→CEF broadcast edge works.
// Sub-cycle B gate: BOTH windows must tick (broadcast fans into every live
// CEF browser, not just the first).
Events.on("tick", (data: { n: number }) => {
  tick.textContent = `worker tick #${data.n}`;
});

goButton.addEventListener("click", async () => {
  out.textContent = "...";
  try {
    out.textContent = await Services.invoke<string, { name: string }>("greet", { name: "CEF" });
  } catch (e) {
    out.textContent = `error: ${e}`;
  }
});
