import { describe, expect, it } from "bun:test";
import {
  renderZServiceDispatchers,
} from "./z-service-dispatcher";
import type { ZServiceManifest } from "./z-service-bindings";

const manifest: ZServiceManifest = {
  schemaVersion: 2,
  types: [
    {
      name: "CreateNoteInput",
      module: "/workspace/app/notes-core.zs",
      fields: [{ name: "title", type: "String" }],
    },
    {
      name: "Note",
      module: "/workspace/app/notes-core.zs",
      fields: [
        { name: "id", type: "u64" },
        { name: "title", type: "String" },
      ],
    },
  ],
  services: [{
    name: "notes",
    type: "NotesService",
    kind: "class",
    module: "/workspace/app/notes-service.zs",
    lifecycle: true,
    registration: {
      module: "/workspace/app/main.zs",
      offset: 100,
      line: 20,
      column: 24,
      method: "ApplicationServicesBuilder.register",
    },
    methods: [
      {
        id: 3_539_395_672,
        name: "create",
        input: "CreateNoteInput",
        inputMode: "value",
        returns: "Note",
        asynchronous: false,
        executorAffinity: null,
        receiverMode: "in",
      },
      {
        id: 1_604_992_403,
        name: "count",
        returns: "u64",
        asynchronous: true,
        executorAffinity: "thread.main",
        receiverMode: "in",
      },
    ],
  }],
};

describe("generated Z service dispatch", () => {
  it("lowers typed calls, ownership, executor placement, and codecs", () => {
    const source = renderZServiceDispatchers(manifest, {
      outputPath: "/workspace/generated/service-dispatchers.zs",
      serviceContractModule: "/workspace/framework/service-contract.zs",
      servicesModule: "/workspace/framework/services.zs",
      asyncServiceContractModule: "/workspace/framework/async-service-contract.zs",
      serviceLifecycleContractModule: "/workspace/framework/service-lifecycle-contract.zs",
    });
    expect(source).toContain(
      'import { CreateNoteInput, Note } from "../app/notes-core.zs";',
    );
    expect(source).toContain(
      'import { NotesService } from "../app/notes-service.zs";',
    );
    expect(source).toContain("// Static method ID: 3539395672");
    expect(source).toContain("service.create(move input)");
    expect(source).toContain("function __zappDispatchNotesServiceCreate(");
    expect(source).toContain("return __zappDispatchNotesServiceCreate(");
    expect(source).toContain("await on thread.main service.count()");
    expect(source).toContain("__zappDecodeCreateNoteInput");
    expect(source).toContain("__zappEncodeNote");
    expect(source).toContain('ServiceOutcome.failure("UNKNOWN_METHOD")');
    expect(source).toContain(
      "class __ZappNotesServiceAdapter implements AsyncService, ServiceLifecycle",
    );
    expect(source).toContain("function __zappAdaptNotes(");
  });

  it("rejects writable request capabilities at generation time", () => {
    const invalid = structuredClone(manifest);
    invalid.services[0].methods[0].inputMode = "inout";
    expect(() => renderZServiceDispatchers(invalid, {
      outputPath: "/workspace/generated/service-dispatchers.zs",
      serviceContractModule: "/workspace/framework/service-contract.zs",
      servicesModule: "/workspace/framework/services.zs",
      asyncServiceContractModule: "/workspace/framework/async-service-contract.zs",
      serviceLifecycleContractModule: "/workspace/framework/service-lifecycle-contract.zs",
    })).toThrow(/does not support inout input capability/);
  });

  it("keeps synchronous struct services on the non-task adapter path", () => {
    const synchronous = structuredClone(manifest);
    synchronous.services[0].kind = "struct";
    synchronous.services[0].lifecycle = false;
    synchronous.services[0].methods = [synchronous.services[0].methods[0]];
    const source = renderZServiceDispatchers(synchronous, {
      outputPath: "/workspace/generated/service-dispatchers.zs",
      serviceContractModule: "/workspace/framework/service-contract.zs",
      servicesModule: "/workspace/framework/services.zs",
      asyncServiceContractModule: "/workspace/framework/async-service-contract.zs",
      serviceLifecycleContractModule: "/workspace/framework/service-lifecycle-contract.zs",
    });
    expect(source).toContain('import { Service } from "../framework/services.zs";');
    expect(source).not.toContain("import { AsyncService }");
    expect(source).toContain("class __ZappNotesServiceAdapter implements Service");
    expect(source).toContain("function __zappInvokeNotes(");
    expect(source).toContain("const target = this.service;");
    expect(source).toContain("in target");
    expect(source).toContain("new __ZappNotesServiceAdapter({ service: service })");
  });
});
