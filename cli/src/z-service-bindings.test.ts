import { describe, expect, it } from "bun:test";
import {
  generateZServiceBindings,
  renderZServiceBindings,
  type ZServiceManifest,
} from "./z-service-bindings";
import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

const manifest: ZServiceManifest = {
  schemaVersion: 5,
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
  enums: [],
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
      method: "ApplicationServices.register",
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
  it("does not rewrite an unchanged binding during a native dev build", async () => {
    const directory = await mkdtemp(path.join(tmpdir(), "zapp-service-bindings-"));
    try {
      const output = await generateZServiceBindings(manifest, directory);
      const first = await stat(output);
      await new Promise((resolve) => setTimeout(resolve, 10));
      await generateZServiceBindings(manifest, directory);
      const second = await stat(output);
      expect(second.mtimeMs).toBe(first.mtimeMs);
      expect(await readFile(output, "utf8")).toBe(renderZServiceBindings(manifest));
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

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
    expect(source).not.toContain("__zappServices");
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
    expect(bindings).toContain("decoded.push(decodeNumber(value[index]))");

  });

  it("maps explicit options to null and preserves optional field omission", () => {
    const optional = structuredClone(manifest);
    optional.types.push({
      name: "NoteSelection",
      module: "/app.zs",
      fields: [
        { name: "selected", type: "Option<Note>" },
        { name: "subtitle", type: "Option<String>", optional: true },
        { name: "related", type: "Option<Array<Note>>" },
      ],
    });
    optional.services[0].methods.push({
      id: 2,
      name: "find",
      input: "Option<u64>",
      inputMode: "value",
      returns: "Option<Note>",
      asynchronous: false,
      executorAffinity: null,
      receiverMode: "in",
    });

    const bindings = renderZServiceBindings(optional);
    expect(bindings).toContain("selected: Note | null;");
    expect(bindings).toContain("subtitle?: string | null;");
    expect(bindings).toContain("related: Array<Note> | null;");
    expect(bindings).toContain(
      "find(input: bigint | null, options?: InvokeOptions): CancellablePromise<Note | null>",
    );
    expect(bindings).toContain("function decodeOptionOfNote(value: unknown): Note | null");
    expect(bindings).toContain("if (value === null) return null");
    expect(bindings).toContain(
      "subtitle: decodeOptionOfString((record.subtitle === undefined ? null : record.subtitle))",
    );
    expect(bindings).toContain(
      "subtitle: encodeOptionOfString((value.subtitle ?? null))",
    );

  });

  it("emits payload-free enums as checked string unions with runtime values", () => {
    const withEnum = structuredClone(manifest);
    withEnum.enums.push({
      name: "NoteState",
      module: "/app.zs",
      variants: [{ name: "active" }, { name: "archived" }],
    });
    withEnum.types[0].fields.push({ name: "state", type: "NoteState" });
    withEnum.types[1].fields.push({ name: "state", type: "NoteState" });

    const bindings = renderZServiceBindings(withEnum);
    expect(bindings).toContain(`export const NoteState = {
  active: "active",
  archived: "archived",
} as const;`);
    expect(bindings).toContain(
      "export type NoteState = typeof NoteState[keyof typeof NoteState];",
    );
    expect(bindings).toContain("state: NoteState;");
    expect(bindings).toContain("const NoteStateValues = new Set<string>(Object.values(NoteState))");
    expect(bindings).toContain("function decodeNoteState(value: unknown): NoteState");

  });

  it("emits payload enums as tagged unions with checked constructors and codecs", () => {
    const withEnum = structuredClone(manifest);
    withEnum.enums.push({
      name: "NoteDescription",
      module: "/app.zs",
      variants: [
        { name: "described", payload: "String" },
        { name: "unavailable" },
      ],
    });
    withEnum.services[0].methods.push({
      id: 3,
      name: "describe",
      input: "NoteDescription",
      inputMode: "value",
      returns: "NoteDescription",
      asynchronous: false,
      executorAffinity: null,
      receiverMode: "in",
    });

    const bindings = renderZServiceBindings(withEnum);
    expect(bindings).toContain(`export type NoteDescription =
  | { kind: "described"; value: string }
  | { kind: "unavailable" };`);
    expect(bindings).toContain(
      'described: (value: string): NoteDescription => ({ kind: "described", value })',
    );
    expect(bindings).toContain(
      'unavailable: { kind: "unavailable" } as const',
    );
    expect(bindings).toContain("const record = decodeRecord(value)");
    expect(bindings).toContain('case "described":');
    expect(bindings).toContain('value: decodeString(record.value)');
    expect(bindings).toContain('value: encodeString(value.value)');

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
