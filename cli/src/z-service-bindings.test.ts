import { describe, expect, it } from "bun:test";
import {
  renderZServiceBindings,
  renderZServiceWebviewRuntime,
  type ZServiceManifest,
} from "./z-service-bindings";

const manifest: ZServiceManifest = {
  schemaVersion: 2,
  types: [
    {
      name: "CreateNoteInput",
      fields: [{ name: "title", type: "String" }],
    },
    {
      name: "Note",
      fields: [
        { name: "id", type: "u64" },
        { name: "title", type: "String" },
      ],
    },
  ],
  services: [{
    name: "notes",
    type: "NotesService",
    methods: [
      {
        id: 3_539_395_672,
        name: "create",
        input: "CreateNoteInput",
        returns: "Note",
        asynchronous: false,
        executorAffinity: null,
      },
      {
        id: 1_604_992_403,
        name: "count",
        returns: "u64",
        asynchronous: true,
        executorAffinity: "thread.main",
      },
    ],
  }],
};

describe("Z service binding generation", () => {
  it("generates typed cancellable bindings with exact integer decoding", () => {
    const source = renderZServiceBindings(manifest);
    expect(source).toContain("export interface Note");
    expect(source).toContain("id: bigint;");
    expect(source).toContain('Services.invoke<unknown, unknown>(\n        "notes.create"');
    expect(source).toContain("input: CreateNoteInput, options?: InvokeOptions");
    expect(source).toContain("count(options?: InvokeOptions)");
    expect(source).toContain("options,\n      )");
    expect(source).toContain("mapped.cancel = () => source.cancel()");
    expect(source).toContain("return BigInt(value)");
  });

  it("installs the same service names into the WebView runtime", () => {
    const source = renderZServiceWebviewRuntime(manifest);
    expect(source).toContain(
      'bridge.invoke("notes.create", encodeCreateNoteInput(input), options)',
    );
    expect(source).toContain("globalThis.__zappServices");
    expect(source).toContain(
      'decodeU64(value["id"])',
    );
  });
});
