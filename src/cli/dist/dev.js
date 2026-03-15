import http from "node:http";
import path from "node:path";
import process from "node:process";
import { killChild, preferredJsTool, runCmd, sleep, spawnPackageScript, spawnStreaming, } from "./common.mjs";
const waitForUrl = async (url, timeoutMs) => {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
        const ok = await new Promise((resolve) => {
            const req = http.get(url, (res) => {
                res.resume();
                resolve((res.statusCode ?? 500) < 500);
            });
            req.on("error", () => resolve(false));
        });
        if (ok)
            return;
        await sleep(350);
    }
    throw new Error(`Timed out waiting for ${url}`);
};
export const runDev = async ({ root, frontendDir, buildFile, nativeOut }) => {
    process.stdout.write(`[zapp] starting dev orchestration (${preferredJsTool()})\n`);
    const vite = spawnPackageScript("dev", { cwd: frontendDir });
    let app = null;
    let shuttingDown = false;
    const shutdown = () => {
        if (shuttingDown)
            return;
        shuttingDown = true;
        killChild(app);
        killChild(vite);
        setTimeout(() => process.exit(0), 200).unref();
    };
    process.on("SIGINT", shutdown);
    process.on("SIGTERM", shutdown);
    process.on("exit", shutdown);
    try {
        await waitForUrl("http://localhost:5173", 30000);
        await runCmd("zc", ["build", buildFile, "-o", nativeOut], { cwd: root });
        app = spawnStreaming(nativeOut, [], {
            cwd: root,
            env: {
                ZAPP_WEBVIEW_MODE: "dev",
            },
        });
        app.once("close", (code) => {
            process.stdout.write(`[zapp] native process exited (${code ?? "null"})\n`);
            shutdown();
        });
        vite.once("close", (code) => {
            process.stdout.write(`[zapp] vite exited (${code ?? "null"})\n`);
            shutdown();
        });
    }
    catch (error) {
        shutdown();
        throw error;
    }
    await new Promise(() => { });
    return path.resolve(root);
};
