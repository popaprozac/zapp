import { describe, expect, it } from "bun:test";
import type { ZServiceManifest } from "./z-service-bindings";
import { rewriteZServiceRegistrationModule } from "./z-service-registration";

function manifestFor(source: string): ZServiceManifest {
  const method = "register";
  return {
    schemaVersion: 3,
    types: [],
    errors: [],
    services: [{
      name: "notes",
      type: "NotesService",
      kind: "class",
      module: "/workspace/app/notes-service.zs",
      lifecycle: true,
      registration: {
        module: "/workspace/app/main.zs",
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
  it("installs the generated adapter into the staged registration only", () => {
    const source = `import { createNotesService } from "./notes-service.zs";

function main(): i32 {
  app.services.register(
    "notes",
    createNotesService()
  );
  return 0;
}
`;
    const rewritten = rewriteZServiceRegistrationModule(
      source,
      "/workspace/app/main.zs",
      "/workspace/generated/service-dispatchers.zs",
      manifestFor(source),
    );
    expect(rewritten).toStartWith(
      'import { __zappAdaptNotes } from "../generated/service-dispatchers.zs";\n',
    );
    expect(rewritten).toContain("app.services.__registerGeneratedAsyncWithLifecycle(");
    expect(rewritten).toContain("__zappAdaptNotes(createNotesService()\n  ));");
  });

  it("fails closed when compiler metadata no longer points at the checked call", () => {
    const source = 'app.services.register("notes", service);\n';
    const manifest = manifestFor(source);
    manifest.services[0].registration.offset += 1;
    expect(() => rewriteZServiceRegistrationModule(
      source,
      "/workspace/app/main.zs",
      "/workspace/generated/service-dispatchers.zs",
      manifest,
    )).toThrow(/stale service metadata/);
  });

  it("selects the generated synchronous fast path from method metadata", () => {
    const source = 'app.services.register("health", service);\n';
    const manifest = manifestFor(source);
    manifest.services[0].lifecycle = false;
    manifest.services[0].methods[0].asynchronous = false;
    manifest.services[0].methods[0].executorAffinity = null;
    const rewritten = rewriteZServiceRegistrationModule(
      source,
      "/workspace/app/main.zs",
      "/workspace/generated/service-dispatchers.zs",
      manifest,
    );
    expect(rewritten).toContain("app.services.__registerGenerated(");
  });
});
