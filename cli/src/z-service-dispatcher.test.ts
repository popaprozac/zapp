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
    module: "/workspace/app/notes-service.zs",
    lifecycle: true,
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
    });
    expect(source).toContain(
      'import { CreateNoteInput, Note } from "../app/notes-core.zs";',
    );
    expect(source).toContain(
      'import { NotesService } from "../app/notes-service.zs";',
    );
    expect(source).toContain("// Static method ID: 3539395672");
    expect(source).toContain("service.create(move input)");
    expect(source).toContain("await on thread.main service.count()");
    expect(source).toContain("__zappDecodeCreateNoteInput");
    expect(source).toContain("__zappEncodeNote");
    expect(source).toContain('ServiceOutcome.failure("UNKNOWN_METHOD")');
  });

  it("rejects writable request capabilities at generation time", () => {
    const invalid = structuredClone(manifest);
    invalid.services[0].methods[0].inputMode = "inout";
    expect(() => renderZServiceDispatchers(invalid, {
      outputPath: "/workspace/generated/service-dispatchers.zs",
      serviceContractModule: "/workspace/framework/service-contract.zs",
    })).toThrow(/does not support inout input capability/);
  });
});
