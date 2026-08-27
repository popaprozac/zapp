import { resolve } from "node:path";
import { compileNative } from "../../cli/src/native";
import {
  createConfigContext,
  loadConfig,
} from "../../cli/src/config";

const spike = import.meta.dir;
const repository = resolve(spike, "../..");
const output = resolve(spike, "build", "zapp-z-webview");

async function run(
  command: string[],
  env?: Record<string, string | undefined>,
): Promise<void> {
  const child = Bun.spawn(command, {
    cwd: repository,
    env,
    stdout: "inherit",
    stderr: "inherit",
  });
  const status = await child.exited;
  if (status !== 0) {
    throw new Error(`${command[0]} exited with status ${status}`);
  }
}

const smoke = process.argv.includes("--smoke");
const devSmoke = process.argv.includes("--dev-smoke");
const config = await loadConfig(
  spike,
  createConfigContext(spike, devSmoke ? "dev" : "build", "macos"),
);

const devServer = devSmoke
  ? Bun.serve({
      hostname: "127.0.0.1",
      port: 0,
      async fetch(request) {
        const pathname = new URL(request.url).pathname;
        const asset = pathname === "/app.js" ? "app.js" : "index.html";
        return new Response(await Bun.file(resolve(spike, "frontend", asset)).bytes(), {
          headers: {
            "Content-Type": asset.endsWith(".js")
              ? "text/javascript; charset=utf-8"
              : "text/html; charset=utf-8",
          },
        });
      },
    })
  : null;
const devUrl = devServer === null
  ? undefined
  : `http://127.0.0.1:${devServer.port}`;

const originalLanguage = process.env.ZAPP_NATIVE_LANG;
const originalHost = process.env.ZAPP_Z_HOST;
let compiled = false;
process.env.ZAPP_NATIVE_LANG = "z";
process.env.ZAPP_Z_HOST = "desktop";
try {
  await compileNative({
    root: spike,
    buildFile: "",
    buildConfigFile: "",
    nativeDir: resolve(repository, "native"),
    output,
    optimize: true,
    target: "macos",
    config,
    devUrl,
  });
  compiled = true;
} finally {
  if (originalLanguage === undefined) delete process.env.ZAPP_NATIVE_LANG;
  else process.env.ZAPP_NATIVE_LANG = originalLanguage;
  if (originalHost === undefined) delete process.env.ZAPP_Z_HOST;
  else process.env.ZAPP_Z_HOST = originalHost;
  if (!compiled) devServer?.stop(true);
}

try {
  await run(
    [output],
    smoke || devSmoke
      ? { ...process.env, ZAPP_Z_DESKTOP_SMOKE: "1" }
      : process.env,
  );
} finally {
  devServer?.stop(true);
}
