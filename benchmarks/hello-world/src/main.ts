import { App, Window, WindowEvent, Services } from "@zapp/runtime";

const win = Window.current();

win.on(WindowEvent.READY, () => {
  console.log("[benchmark] window ready");
});

// Simple interaction: call a service
document.getElementById("greet-btn")?.addEventListener("click", async () => {
  const input = document.getElementById("name-input") as HTMLInputElement;
  const result = await Services.invoke("greet", { name: input?.value ?? "World" });
  const output = document.getElementById("output");
  if (output) output.textContent = `Hello, ${(result as { name: string }).name}!`;
});
