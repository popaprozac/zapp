import { afterEach, describe, expect, it } from "bun:test";
import path from "node:path";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { zapp } from "../../vite/src/index";

const temporary: string[] = [];

afterEach(async () => {
  await Promise.all(temporary.splice(0).map((directory) => (
    rm(directory, { recursive: true, force: true })
  )));
});

function resolveServices(plugin: ReturnType<typeof zapp>): unknown {
  return (plugin.resolveId as (id: string) => unknown)("zapp:services");
}

describe("the unified Zapp Vite plugin", () => {
  it("finds generated services above a nested frontend root", async () => {
    const project = await mkdtemp(path.join(tmpdir(), "zapp-vite-"));
    temporary.push(project);
    const frontend = path.join(project, "frontend");
    const generated = path.join(project, ".zapp", "generated", "services.ts");
    await mkdir(path.dirname(generated), { recursive: true });
    await mkdir(frontend, { recursive: true });
    await writeFile(path.join(project, "zapp.config.ts"), "export default {};\n");
    await writeFile(generated, "export const notes = {};\n");

    const plugin = zapp();
    (plugin.configResolved as (config: unknown) => void)({
      root: frontend,
      command: "build",
      mode: "production",
      resolve: { alias: [] },
    });

    expect(resolveServices(plugin)).toBe(generated);
  });

  it("fails with an actionable diagnostic when generation was skipped", async () => {
    const project = await mkdtemp(path.join(tmpdir(), "zapp-vite-"));
    temporary.push(project);
    await writeFile(path.join(project, "zapp.config.ts"), "export default {};\n");

    const plugin = zapp();
    (plugin.configResolved as (config: unknown) => void)({
      root: project,
      command: "build",
      mode: "production",
      resolve: { alias: [] },
    });

    expect(() => resolveServices(plugin)).toThrow("generated services are missing");
    expect(() => resolveServices(plugin)).toThrow("zapp dev");
  });
});
