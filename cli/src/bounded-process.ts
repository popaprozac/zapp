export interface BoundedCommandResult {
  status: number;
  stdout: string;
  stderr: string;
  timedOut: boolean;
}

export interface BoundedCommandOptions {
  cwd: string;
  timeoutMs: number;
  env?: Record<string, string>;
}

type ManagedSubprocess = ReturnType<typeof Bun.spawn>;

export function signalProcessTree(
  child: ManagedSubprocess,
  signal: "SIGTERM" | "SIGKILL" = "SIGTERM",
): void {
  if (process.platform === "win32") {
    Bun.spawnSync(["taskkill", "/F", "/T", "/PID", String(child.pid)], {
      stdout: "ignore",
      stderr: "ignore",
    });
    return;
  }
  try {
    process.kill(-child.pid, signal);
  } catch {
    try {
      child.kill(signal);
    } catch {
      // The process may have exited between observation and signalling.
    }
  }
}

async function exitsWithin(
  child: ManagedSubprocess,
  timeoutMs: number,
): Promise<boolean> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      child.exited.then(() => true),
      new Promise<boolean>((resolve) => {
        timer = setTimeout(() => resolve(false), timeoutMs);
      }),
    ]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

/** Stop a detached child and its descendants, waiting for the port/resources
 * owned by that tree to be released before returning. */
export async function terminateProcessTree(
  child: ManagedSubprocess | null,
  graceMs = 1_500,
): Promise<void> {
  if (child === null) return;
  if (child.exitCode !== null) return;
  signalProcessTree(child, "SIGTERM");
  if (await exitsWithin(child, graceMs)) return;
  signalProcessTree(child, "SIGKILL");
  await exitsWithin(child, graceMs);
}

/**
 * Run one child for a deliberately bounded amount of time.
 *
 * This is intended for native fixtures and host-tool probes whose runtime may
 * be broken independently of the program under test. A timeout always kills
 * the direct child before the result resolves.
 */
export async function runBoundedCommand(
  command: string[],
  options: BoundedCommandOptions,
): Promise<BoundedCommandResult> {
  const child = Bun.spawn(command, {
    cwd: options.cwd,
    env: { ...process.env, ...options.env },
    detached: process.platform !== "win32",
    stdout: "pipe",
    stderr: "pipe",
  });
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    if (process.platform !== "win32") {
      try {
        signalProcessTree(child, "SIGKILL");
        return;
      } catch {
        // Fall through when the child exited between the timeout and signal.
      }
    }
    child.kill("SIGKILL");
  }, options.timeoutMs);
  try {
    const [stdout, stderr, status] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
      child.exited,
    ]);
    return { status, stdout, stderr, timedOut };
  } finally {
    clearTimeout(timer);
  }
}
