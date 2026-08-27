import { resolve } from "node:path";

const spike = import.meta.dir;
const repository = resolve(spike, "../..");
const cli = resolve(repository, "cli/src/zapp-cli.ts");
const smoke = process.argv.includes("--smoke");

const child = Bun.spawn(
  [process.execPath, cli, "dev", "-r", spike],
  {
    cwd: repository,
    env: {
      ...process.env,
      ZAPP_NATIVE_LANG: "z",
      ...(smoke ? { ZAPP_Z_DESKTOP_SMOKE: "1" } : {}),
    },
    stdin: "inherit",
    stdout: "inherit",
    stderr: "inherit",
  },
);

const stop = () => {
  try {
    child.kill();
  } catch {
    // The CLI may already have completed its own deterministic cleanup.
  }
};

process.on("SIGINT", stop);
process.on("SIGTERM", stop);

const status = await child.exited;
if (smoke && status === 0) {
  const portProbe = Bun.serve({
    hostname: "127.0.0.1",
    port: 5173,
    fetch: () => new Response("released"),
  });
  portProbe.stop(true);
  console.log("Z Notes dev smoke released Vite port 5173");
}
process.exitCode = status;
