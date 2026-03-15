import { spawn, spawnSync } from "node:child_process";
import process from "node:process";
export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
let cachedExec = null;
export const preferredJsTool = () => {
    if (cachedExec)
        return cachedExec;
    const bun = spawnSync("bun", ["--version"], { stdio: "ignore" });
    if (bun.status === 0) {
        cachedExec = "bun";
        return cachedExec;
    }
    cachedExec = "npm";
    return cachedExec;
};
export const runCmd = (command, args, options = {}) => new Promise((resolve, reject) => {
    const child = spawn(command, args, {
        cwd: options.cwd ?? process.cwd(),
        stdio: "inherit",
        shell: false,
        env: { ...process.env, ...(options.env ?? {}) },
    });
    child.once("error", reject);
    child.once("close", (code) => {
        if (code === 0)
            resolve();
        else
            reject(new Error(`${command} ${args.join(" ")} failed (${code ?? "null"})`));
    });
});
export const spawnStreaming = (command, args, options = {}) => spawn(command, args, {
    cwd: options.cwd ?? process.cwd(),
    stdio: "inherit",
    shell: false,
    env: { ...process.env, ...(options.env ?? {}) },
});
export const killChild = (child) => {
    if (!child || child.killed)
        return;
    try {
        child.kill("SIGTERM");
    }
    catch {
        // Ignore.
    }
};
export const runPackageScript = (script, options = {}) => {
    const tool = preferredJsTool();
    const args = tool === "bun" ? ["run", script] : ["run", script];
    return runCmd(tool, args, options);
};
export const spawnPackageScript = (script, options = {}) => {
    const tool = preferredJsTool();
    const args = tool === "bun" ? ["run", script] : ["run", script];
    return spawnStreaming(tool, args, options);
};
