import { Electroview } from "electrobun/view";
import type { BenchSchema } from "../shared/schema";

const rpc = Electroview.defineRPC<BenchSchema>({
  handlers: { requests: {} },
});

new Electroview({ rpc });

// Benchmark hook: bridge-bench.ts pasted into devtools calls this.
(globalThis as unknown as { __bench: { ping: () => Promise<unknown> } }).__bench = {
  ping: () => rpc.request.ping(),
};

const button = document.getElementById("ping") as HTMLButtonElement;
const out = document.getElementById("out") as HTMLDivElement;

button.addEventListener("click", async () => {
  const r = await rpc.request.ping();
  out.textContent = `pong: ${r.pong}`;
});
