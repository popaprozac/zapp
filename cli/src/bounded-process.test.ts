import { describe, expect, it } from "bun:test";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { resolve } from "node:path";
import { runBoundedCommand, terminateProcessTree } from "./bounded-process";

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

  it("kills descendants when a bounded command times out", async () => {
    const directory = mkdtempSync("/tmp/zapp-bounded-process-");
    try {
      const marker = resolve(directory, "escaped");
      const descendant = [
        "await Bun.sleep(250);",
        `await Bun.write(${JSON.stringify(marker)}, "escaped");`,
      ].join(" ");
      const parent = [
        `Bun.spawn([process.execPath, "-e", ${JSON.stringify(descendant)}], {`,
        '  stdout: "ignore", stderr: "ignore",',
        "});",
        "setInterval(() => {}, 1_000);",
      ].join("\n");

      const result = await runBoundedCommand(
        [process.execPath, "-e", parent],
        { cwd: import.meta.dir, timeoutMs: 50 },
      );

      expect(result.timedOut).toBe(true);
      await Bun.sleep(400);
      expect(existsSync(marker)).toBe(false);
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("awaits deterministic shutdown of a detached process tree", async () => {
    const directory = mkdtempSync("/tmp/zapp-managed-process-");
    try {
      const marker = resolve(directory, "escaped");
      const descendant = [
        "await Bun.sleep(250);",
        `await Bun.write(${JSON.stringify(marker)}, "escaped");`,
      ].join(" ");
      const parent = [
        `Bun.spawn([process.execPath, "-e", ${JSON.stringify(descendant)}], {`,
        '  stdout: "ignore", stderr: "ignore",',
        "});",
        "setInterval(() => {}, 1_000);",
      ].join("\n");
      const child = Bun.spawn([process.execPath, "-e", parent], {
        cwd: import.meta.dir,
        detached: process.platform !== "win32",
        stdout: "ignore",
        stderr: "ignore",
      });

      await Bun.sleep(50);
      await terminateProcessTree(child);
      await Bun.sleep(400);

      expect(existsSync(marker)).toBe(false);
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });
});
