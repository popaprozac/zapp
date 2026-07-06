// cef-hello — the render+bridge smoke target for the CEF `webEngine:"chromium"`
// production slice. One button, one service call: click → `greet` round-trips
// through Services.invoke (webview → Nim router → back), same bridge path
// WKWebView uses today, on whatever engine `zapp.config.ts`'s `webEngine`
// resolves to.
import { Events, Services } from "@zappdev/runtime";

const goButton = document.querySelector<HTMLButtonElement>("#go")!;
const out = document.querySelector<HTMLPreElement>("#out")!;
const tick = document.querySelector<HTMLPreElement>("#tick")!;

// Sub-cycle A gate: the ticker worker broadcasts `tick` every second; render it.
// If this increments on a chromium build, the worker→CEF broadcast edge works.
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
