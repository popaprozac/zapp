import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import process from "node:process";

export const sleep = (ms: number) => Bun.sleep(ms);

let cachedExec: string | null = null;

export const preferredJsTool = (): string => {
  if (cachedExec) return cachedExec;
  if (Bun.which("bun")) {
    cachedExec = "bun";
    return cachedExec;
  }
  cachedExec = "npm";
  return cachedExec;
};

export const runCmd = async (command: string, args: string[], options: any = {}) => {
  const { $ } = require("bun");
  const env = { ...process.env, ...(options.env ?? {}) };
  const cwd = options.cwd ?? process.cwd();
  
  if (command === "bun") {
    await $`bun ${args}`.cwd(cwd).env(env);
  } else if (command === "zc") {
    await $`zc ${args}`.cwd(cwd).env(env);
  } else {
    const cmdPath = Bun.which(command) || command;
    const proc = Bun.spawn([cmdPath, ...args], {
      cwd,
      stdio: ["inherit", "inherit", "inherit"],
      env,
    });
    const code = await proc.exited;
    if (code !== 0) {
      throw new Error(`${command} ${args.join(" ")} failed (${code})`);
    }
  }
};

export const spawnStreaming = (command: string, args: string[], options: any = {}) => {
  const cmdPath = Bun.which(command) || command;
  return Bun.spawn([cmdPath, ...args], {
    cwd: options.cwd ?? process.cwd(),
    stdio: ["inherit", "inherit", "inherit"],
    env: { ...process.env, ...(options.env ?? {}) },
  });
};

export const killChild = (child: import("bun").Subprocess | null | any) => {
  if (!child || child.killed) return;
  try {
    child.kill("SIGTERM");
  } catch {
    try { child.kill(9); } catch { /* ignore */ }
  }
};

export const runPackageScript = (script: string, options: any = {}) => {
  const tool = preferredJsTool();
  const args = tool === "bun" ? ["run", script] : ["run", script];
  return runCmd(tool, args, options);
};

export const spawnPackageScript = (script: string, options: any = {}) => {
  const tool = preferredJsTool();
  const args = tool === "bun" ? ["run", script] : ["run", script];
  return spawnStreaming(tool, args, options);
};
