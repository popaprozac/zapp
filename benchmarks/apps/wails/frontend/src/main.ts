import { PingService } from "../bindings/changeme";

const button = document.getElementById("ping") as HTMLButtonElement;
const out = document.getElementById("out") as HTMLDivElement;

button.addEventListener("click", async () => {
  const r = await PingService.Ping();
  out.textContent = `pong: ${r.pong}`;
});

// Benchmark hook: bridge-bench.ts pasted into devtools calls this.
(globalThis as unknown as { __bench: { ping: () => Promise<unknown> } }).__bench = {
  ping: () => PingService.Ping(),
};
