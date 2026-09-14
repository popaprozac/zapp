// Vite lives in its own process so a stuck transform/close cannot spin the
// native-test coordinator. The parent bounds startup and owns termination.
import { createServer } from "vite";
import { rename } from "node:fs/promises";
import { zapp } from "../../vite/src/index";

const [root, readiness] = process.argv.slice(2);
if (!root || !readiness) throw new Error("expected assets and readiness paths");
const server = await createServer({ root, configFile: false, plugins: [zapp()],
  server: { host: "127.0.0.1", port: 0 }, logLevel: "silent" });
await server.listen();
const address = server.httpServer!.address();
if (address === null || typeof address === "string") throw new Error("missing Vite port");
await Bun.write(`${readiness}.tmp`, JSON.stringify({ port: address.port }));
await rename(`${readiness}.tmp`, readiness);
process.once("SIGTERM", () => { void server.close().then(() => process.exit(0)); });
