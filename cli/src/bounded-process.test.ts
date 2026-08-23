import { describe, expect, it } from "bun:test";
import { runBoundedCommand } from "./bounded-process";

describe("runBoundedCommand", () => {
  it("captures a child that exits normally", async () => {
    const result = await runBoundedCommand(
      [process.execPath, "-e", 'console.log("complete")'],
      { cwd: import.meta.dir, timeoutMs: 5_000 },
    );

    expect(result.timedOut).toBe(false);
    expect(result.status).toBe(0);
    expect(result.stdout).toBe("complete\n");
  });

  it("kills a child that exceeds its deadline", async () => {
    const started = performance.now();
    const result = await runBoundedCommand(
      [process.execPath, "-e", "setInterval(() => {}, 1_000)"],
      { cwd: import.meta.dir, timeoutMs: 50 },
    );

    expect(result.timedOut).toBe(true);
    expect(result.status).not.toBe(0);
    expect(performance.now() - started).toBeLessThan(2_000);
  });
});
