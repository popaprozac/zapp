import { describe, expect, it } from "bun:test";
import {
  renderZServiceBindings,
  renderZServiceWebviewRuntime,
  type ZServiceManifest,
} from "./z-service-bindings";

const manifest: ZServiceManifest = {
  schemaVersion: 3,
  types: [
    {
      name: "CreateNoteInput",
      module: "/app.zs",
      fields: [{ name: "title", type: "String" }],
    },
    {
      name: "Note",
      module: "/app.zs",
      fields: [
        { name: "id", type: "u64" },
        { name: "title", type: "String" },
      ],
    },
  ],
  errors: [{
    name: "NoteCreationError",
    module: "/app.zs",
    fields: [
      { name: "message", type: "String" },
      { name: "title", type: "String" },
    ],
  }],
  services: [{
    name: "notes",
    type: "NotesService",
    kind: "class",
    module: "/app.zs",
    lifecycle: true,
    registration: {
      module: "/app.zs",
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
        error: "NoteCreationError",
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
    expect(source).toContain("export class NoteCreationError extends ZappError");
    expect(source).toContain("readonly details: NoteCreationErrorDetails");
    expect(source).toContain("decodeNoteCreationErrorFailure");
    expect(source).toContain('error.errorType === "NoteCreationError"');
  });

  it("installs the same service names into the WebView runtime", () => {
    const source = renderZServiceWebviewRuntime(manifest);
    expect(source).toContain(
      'bridge.invoke("notes.create", encodeCreateNoteInput(input), options)',
    );
    expect(source).toContain("globalThis.__zappServices");
    expect(source).toContain('error.name = "NoteCreationError"');
    expect(source).toContain(
      'decodeU64(value["id"])',
    );
  });

  it("generates recursive Array<T> wire codecs for typed service values", () => {
    const collections = structuredClone(manifest);
    collections.types.push({
      name: "NotesPage",
      module: "/app.zs",
      fields: [
        { name: "notes", type: "Array<Note>" },
        { name: "pages", type: "Array<Array<Note>>" },
        { name: "counts", type: "Array<i32>" },
      ],
    });
    collections.services[0].methods.push({
      id: 1,
      name: "list",
      returns: "NotesPage",
      asynchronous: false,
      executorAffinity: null,
      receiverMode: "in",
    });

    const bindings = renderZServiceBindings(collections);
    expect(bindings).toContain("notes: Array<Note>;");
    expect(bindings).toContain("pages: Array<Array<Note>>;");
    expect(bindings).toContain("counts: Array<number>;");
    expect(bindings).toContain("function decodeArrayOfNote(value: unknown): Array<Note>");
    expect(bindings).toContain(
      "function decodeArrayOfArrayOfNote(value: unknown): Array<Array<Note>>",
    );
    expect(bindings).toContain("notes: decodeArrayOfNote(record.notes)");
    expect(bindings).toContain("return value.map(decodeNumber)");

    const runtime = renderZServiceWebviewRuntime(collections);
    expect(runtime).toContain("const decodeArrayOfNote = value =>");
    expect(runtime).toContain("return value.map(decodeNote)");
    expect(runtime).toContain("const encodeArrayOfArrayOfNote = value =>");
  });

  it("fails closed when nominal and collection codec names collide", () => {
    const invalid = structuredClone(manifest);
    invalid.types.push({
      name: "ArrayOfNote",
      module: "/app.zs",
      fields: [{ name: "notes", type: "Array<Note>" }],
    });
    expect(() => renderZServiceBindings(invalid)).toThrow(
      /produce the same generated codec name "ArrayOfNote"/,
    );
  });
});
