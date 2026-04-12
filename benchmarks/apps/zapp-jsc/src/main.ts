import { Services, Window, WindowEvent } from "@zappdev/runtime";

const win = Window.current();
win.on(WindowEvent.READY, () => win.show());

const button = document.getElementById("ping") as HTMLButtonElement;
const out = document.getElementById("out") as HTMLDivElement;

button.addEventListener("click", async () => {
  const r = (await Services.invoke<{ pong: number }>("ping")) as { pong: number };
  out.textContent = `pong: ${r.pong}`;
});

// Benchmark hook: bridge-bench.ts pasted into devtools calls this.
(globalThis as any).__bench = {
  ping: () => Services.invoke<{ pong: number }>("ping"),
};
