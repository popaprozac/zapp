// cef-hello — the render+bridge smoke target for the CEF `webEngine:"chromium"`
// production slice. One button, one service call: click → `greet` round-trips
// through Services.invoke (webview → Nim router → back), same bridge path
// WKWebView uses today, on whatever engine `zapp.config.ts`'s `webEngine`
// resolves to.
import { Services } from "@zappdev/runtime";

const goButton = document.querySelector<HTMLButtonElement>("#go")!;
const out = document.querySelector<HTMLPreElement>("#out")!;

goButton.addEventListener("click", async () => {
  out.textContent = "...";
  try {
    out.textContent = await Services.invoke<string, { name: string }>("greet", { name: "CEF" });
  } catch (e) {
    out.textContent = `error: ${e}`;
  }
});
