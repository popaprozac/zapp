import { mkdtemp, readFile, rename, rm } from "node:fs/promises";
import path from "node:path";
import { runBoundedCommand } from "./bounded-process";

/** Publish one native object as a deterministic archive without changing an
 * identical existing artifact. The caller still compiles the object normally,
 * so headers, compiler flags, and toolchain changes cannot bypass validation. */
export async function publishNativeArchive(
  object: string,
  archive: string,
  cwd: string,
): Promise<boolean> {
  const temporary = await mkdtemp(path.join(path.dirname(archive), ".zapp-archive-"));
  const pending = path.join(temporary, path.basename(archive));
  try {
    const result = await runBoundedCommand(["ar", "rcs", pending, object], {
      cwd, timeoutMs: 30_000,
      // Apple's archiver otherwise stamps both the member and symbol table.
      env: { ZERO_AR_DATE: "1" },
    });
    if (result.status !== 0 || result.timedOut) {
      throw new Error(`[zapp] could not create native archive ${archive}: ${result.stderr}`);
    }
    const next = await readFile(pending);
    try {
      if (next.equals(await readFile(archive))) return false;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
    await rename(pending, archive);
    return true;
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
}
