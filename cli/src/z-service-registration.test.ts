import { describe, expect, it } from "bun:test";
import { createHash } from "node:crypto";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import type { ZServiceManifest } from "./z-service-bindings";
import { generateZServiceRegistrationOverlay } from "./z-service-registration";

function manifestFor(source: string, module = "/workspace/app/main.zs"): ZServiceManifest {
  const method = "register";
  return {
    schemaVersion: 5,
    types: [],
    enums: [],
    errors: [],
    services: [{
      name: "notes",
      type: "NotesService",
      kind: "class",
      module: "/workspace/app/notes-service.zs",
      lifecycle: true,
      registration: {
        module,
        offset: source.indexOf(method) + method.length,
        line: 4,
        column: 45,
        method: `ApplicationServicesBuilder.${method}`,
      },
      methods: [{
        id: 1,
        name: "count",
        returns: "u64",
        asynchronous: true,
        executorAffinity: "thread.main",
        receiverMode: "in",
      }],
    }],
  };
}

describe("generated Z service registration", () => {
  it("describes checked call adaptation without rewriting staged source", async () => {
    const directory = mkdtempSync("/tmp/zapp-service-registration-");
    const application = path.join(directory, "app", "main.zs");
    const generatedModule = path.join(directory, "generated", "service-dispatchers.zs");
    const overlayPath = path.join(directory, "generated", "service-registration.zbuild.json");
    mkdirSync(path.dirname(application), { recursive: true });
    mkdirSync(path.dirname(generatedModule), { recursive: true });
    const source = `import { createNotesService } from "./notes-service.zs";

function main(): i32 {
  app.services.register(
    "notes",
    createNotesService()
  );
  return 0;
}
`;
    writeFileSync(application, source);
    writeFileSync(generatedModule, "export function __zappAdaptNotes(value: i32): i32 { return value; }\n");
    await generateZServiceRegistrationOverlay(
      manifestFor(source, application),
      generatedModule,
      overlayPath,
    );
    const overlay = JSON.parse(readFileSync(overlayPath, "utf8"));
    expect(overlay).toEqual({
      schemaVersion: 1,
      modules: {
        "zapp/generated/service-dispatchers": {
          source: "./service-dispatchers.zs",
          package: "zapp",
        },
      },
      callAdapters: [{
        source: "../app/main.zs",
        sourceHash: createHash("sha256").update(source).digest("hex"),
        offset: source.indexOf("register") + "register".length,
        target: "ApplicationServicesBuilder.register",
        replacement: "ApplicationServicesBuilder.registerGeneratedAsyncWithLifecycle",
        argument: 1,
        adapter: {
          module: "zapp/generated/service-dispatchers",
          export: "__zappAdaptNotes",
        },
      }],
    });
    expect(readFileSync(application, "utf8")).toBe(source);
    rmSync(directory, { recursive: true, force: true });
  });

  it("rejects unsupported registration metadata before producing an overlay", async () => {
    const source = 'app.services.register("notes", service);\n';
    const manifest = manifestFor(source);
    manifest.services[0].registration.method = "OtherBuilder.register";
    await expect(generateZServiceRegistrationOverlay(
      manifest,
      "/workspace/generated/service-dispatchers.zs",
      "/workspace/generated/service-registration.zbuild.json",
    )).rejects.toThrow(/unsupported method/);
  });

  it("selects the generated synchronous fast path from method metadata", async () => {
    const directory = mkdtempSync("/tmp/zapp-service-registration-sync-");
    const application = path.join(directory, "app", "main.zs");
    const generatedModule = path.join(directory, "generated", "service-dispatchers.zs");
    const overlayPath = path.join(directory, "generated", "service-registration.zbuild.json");
    mkdirSync(path.dirname(application), { recursive: true });
    mkdirSync(path.dirname(generatedModule), { recursive: true });
    const source = 'app.services.register("health", service);\n';
    writeFileSync(application, source);
    writeFileSync(generatedModule, "");
    const manifest = manifestFor(source, application);
    manifest.services[0].lifecycle = false;
    manifest.services[0].methods[0].asynchronous = false;
    manifest.services[0].methods[0].executorAffinity = null;
    await generateZServiceRegistrationOverlay(
      manifest,
      generatedModule,
      overlayPath,
    );
    const overlay = JSON.parse(readFileSync(overlayPath, "utf8"));
    expect(overlay.callAdapters[0].replacement)
      .toBe("ApplicationServicesBuilder.registerGenerated");
    rmSync(directory, { recursive: true, force: true });
  });
});
