import { describe, expect, it } from "bun:test";
import type { ZServiceManifest } from "./z-service-bindings";
import { rewriteZServiceRegistrationModule } from "./z-service-registration";

function manifestFor(source: string): ZServiceManifest {
  const method = "registerAsyncWithLifecycle";
  return {
    schemaVersion: 2,
    types: [],
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
  app.services.registerAsyncWithLifecycle(
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
    expect(rewritten).toContain("app.services.registerAsyncWithLifecycle(");
    expect(rewritten).toContain("__zappAdaptNotes(createNotesService()\n  ));");
  });

  it("fails closed when compiler metadata no longer points at the checked call", () => {
    const source = 'app.services.registerAsyncWithLifecycle("notes", service);\n';
    const manifest = manifestFor(source);
    manifest.services[0].registration.offset += 1;
    expect(() => rewriteZServiceRegistrationModule(
      source,
      "/workspace/app/main.zs",
      "/workspace/generated/service-dispatchers.zs",
      manifest,
    )).toThrow(/stale service metadata/);
  });

  it("leaves synchronous registrations on their allocation-lean runtime path", () => {
    const source = 'app.services.register("health", service);\n';
    const manifest = manifestFor(source);
    manifest.services[0].registration = {
      module: "/workspace/app/main.zs",
      offset: source.indexOf("register") + "register".length,
      line: 1,
      column: 22,
      method: "ApplicationServicesBuilder.register",
    };
    expect(rewriteZServiceRegistrationModule(
      source,
      "/workspace/app/main.zs",
      "/workspace/generated/service-dispatchers.zs",
      manifest,
    )).toBe(source);
  });
});
