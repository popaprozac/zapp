import { expect, test } from "bun:test";
import { mkdtemp, readFile, rm, stat, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { publishNativeArchive } from "./native-archive";
import { runBoundedCommand } from "./bounded-process";

test("native archives ignore timestamps but preserve real object changes and repair corruption", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "zapp-native-archive-"));
  const source = path.join(root, "bridge.c");
  const header = path.join(root, "value.h");
  const object = path.join(root, "bridge.o");
  const archive = path.join(root, "libbridge.a");
  const compile = async () => {
    const result = await runBoundedCommand(["clang", "-c", source, "-o", object], {
      cwd: root, timeoutMs: 30_000,
    });
    expect(result.status, result.stderr).toBe(0);
  };
  try {
    await writeFile(source, '#include "value.h"\nint bridge(void) { return VALUE; }\n');
    await writeFile(header, "#define VALUE 1\n");
    await compile();
    expect(await publishNativeArchive(object, archive, root)).toBe(true);
    const original = await readFile(archive);
    const originalStat = await stat(archive);
    await utimes(object, new Date(1_000), new Date(1_000));
    expect(await publishNativeArchive(object, archive, root)).toBe(false);
    expect((await stat(archive)).mtimeMs).toBe(originalStat.mtimeMs);
    expect((await readFile(archive)).equals(original)).toBe(true);

    await rm(archive);
    expect(await publishNativeArchive(object, archive, root)).toBe(true);
    expect((await readFile(archive)).equals(original)).toBe(true);

    await writeFile(header, "#define VALUE 2\n");
    await compile();
    expect(await publishNativeArchive(object, archive, root)).toBe(true);
    const changed = await readFile(archive);
    expect(changed.equals(original)).toBe(false);
    await writeFile(archive, "corrupt archive");
    expect(await publishNativeArchive(object, archive, root)).toBe(true);
    expect((await readFile(archive)).equals(changed)).toBe(true);

    await expect(publishNativeArchive(path.join(root, "missing.o"), archive, root))
      .rejects.toThrow(/could not create native archive/);
    expect((await readFile(archive)).equals(changed)).toBe(true);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}, 60_000);
