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
        process.kill(-child.pid, "SIGKILL");
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
