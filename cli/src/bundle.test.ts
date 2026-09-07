import { afterEach, expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { mkdtemp, mkdir, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { createDevBundle } from "./bundle";
import type { runBoundedCommand } from "./bounded-process";

const roots: string[] = [];
afterEach(async () => {
  for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true });
});
const config = { name: "Bundle Probe", identifier: "com.example.bundle", version: "0.1.0", assetDir: "dist", deepLinkSchemes: ["probe"] };
const success = { status: 0, stdout: "", stderr: "", timedOut: false };
const pass: typeof runBoundedCommand = async () => success;
async function fixture() {
  const root = await mkdtemp(path.join(tmpdir(), "zapp-bundle-"));
  roots.push(root);
  const binary = path.join(root, "new-host");
  await writeFile(binary, "new executable");
  return { root, binary };
}

test("bundle replacement removes old executables and resources before refreshing the final registration", async () => {
  const { root, binary } = await fixture();
  const app = path.join(root, "bin", "Bundle Probe.app");
  await mkdir(path.join(app, "Contents", "MacOS"), { recursive: true });
  await mkdir(path.join(app, "Contents", "Resources"), { recursive: true });
  await writeFile(path.join(app, "Contents", "MacOS", "old-host"), "old");
  await writeFile(path.join(app, "Contents", "Resources", "old-icon.icns"), "old icon");
  const commands: string[][] = [];
  const run: typeof runBoundedCommand = async (command, options) => {
    commands.push(command);
    expect(options.timeoutMs).toBe(15000);
    if (command[0].endsWith("lsregister")) {
      expect(command).toEqual([command[0], "-f", app]);
      expect(await readdir(path.join(app, "Contents", "MacOS"))).toEqual(["new-host"]);
    } else {
      expect(command.at(-1)).not.toBe(app); // sign/verify the unpublished candidate
      expect(existsSync(path.join(app, "Contents", "MacOS", "old-host"))).toBe(true);
    }
    return success;
  };
  expect(await createDevBundle(root, binary, config, {}, run)).toBe(app);
  expect(commands.length).toBe(3);
  expect(commands[1]).toContain("--verify");
  expect(await readdir(path.join(app, "Contents", "Resources"))).toEqual([]);
  expect(await readdir(path.join(root, "bin"))).toEqual(["Bundle Probe.app"]);
  expect(await readFile(binary, "utf8")).toBe("new executable");
});

test("smoke bundles have a separate directory and identity and never register URL schemes", async () => {
  const { root, binary } = await fixture();
  const app = await createDevBundle(root, binary, config, {}, pass);
  const previous = await readFile(path.join(app, "Contents", "Info.plist"), "utf8");
  const smoke = await createDevBundle(root, binary, config, { smoke: true }, async command => {
    expect(command[0]).toBe("/usr/bin/codesign");
    return success;
  });
  expect(smoke).toBe(path.join(root, ".zapp", "smoke", "bin", "Bundle Probe.app"));
  const plist = await readFile(path.join(smoke, "Contents", "Info.plist"), "utf8");
  expect(plist).toContain("com.example.bundle.smoke.dev");
  expect(plist).not.toContain("CFBundleURLTypes");
  expect(previous).toContain("CFBundleURLTypes");
  expect(await readFile(path.join(app, "Contents", "Info.plist"), "utf8")).toBe(previous);
});

test.each(["sign", "verify", "timeout"])("%s failure preserves the working bundle", async failure => {
  const { root, binary } = await fixture();
  const app = await createDevBundle(root, binary, config, {}, pass);
  const oldPlist = await readFile(path.join(app, "Contents", "Info.plist"), "utf8");
  await writeFile(binary, "candidate");
  const run: typeof runBoundedCommand = async command => {
    if ((failure === "verify") !== command.includes("--verify")) return success;
    return { ...success, status: failure === "timeout" ? 0 : 1, timedOut: failure === "timeout", stderr: "signer unavailable" };
  };
  await expect(createDevBundle(root, binary, { ...config, identifier: "com.example.changed" }, {}, run)).rejects.toThrow(/signer unavailable/);
  expect(await readFile(path.join(app, "Contents", "MacOS", "new-host"), "utf8")).toBe("new executable");
  expect(await readFile(path.join(app, "Contents", "Info.plist"), "utf8")).toBe(oldPlist);
  expect(await readdir(path.join(root, "bin"))).toEqual(["Bundle Probe.app"]);
});

test("registration failure rolls back the bundle and refreshes its restored identity", async () => {
  const { root, binary } = await fixture();
  const app = await createDevBundle(root, binary, config, {}, pass);
  let registrations = 0;
  const run: typeof runBoundedCommand = async command => {
    if (command[0].endsWith("lsregister")) {
      registrations++;
      const plist = await readFile(path.join(app, "Contents", "Info.plist"), "utf8");
      expect(plist).toContain(registrations === 1 ? "com.example.changed.dev" : "com.example.bundle.dev");
      if (registrations === 1) return { ...success, status: 1, stderr: "registration unavailable" };
    }
    return success;
  };
  await expect(createDevBundle(root, binary, { ...config, identifier: "com.example.changed" }, {}, run)).rejects.toThrow(/registration unavailable/);
  expect(registrations).toBe(2);
  expect(await readdir(path.join(root, "bin"))).toEqual(["Bundle Probe.app"]);
});

test("first registration failure does not leave a published or half-signed application", async () => {
  const { root, binary } = await fixture();
  await expect(createDevBundle(root, binary, config, {}, async command => command[0].endsWith("lsregister")
    ? { ...success, status: 1, stderr: "registration unavailable" } : success)).rejects.toThrow();
  expect(await readdir(path.join(root, "bin"))).toEqual([]);
});

test("bundle metadata escapes executable, version, and identity values", async () => {
  const { root } = await fixture();
  const binary = path.join(root, "host&probe");
  await writeFile(binary, "probe");
  const app = await createDevBundle(root, binary, { ...config, version: "1<2", identifier: "test&app" }, {}, pass);
  const plist = await readFile(path.join(app, "Contents", "Info.plist"), "utf8");
  expect(plist).toContain("host&amp;probe");
  expect(plist).toContain("1&lt;2");
  expect(plist).toContain("test&amp;app.dev");
});
